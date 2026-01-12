#!/usr/bin/env bash
set -euo pipefail

################################################################################
# CONFIG: set these to your bootstrap repo where agentctl lives
################################################################################
GITHUB_OWNER="joeyparis"
GITHUB_REPO="agent-host-bootstrap"
GITHUB_REF="main"  # Pin this to a commit SHA for deterministic installs.

# File in repo root. Override via env if you store it elsewhere.
AGENTCTL_PATH="${AGENTCTL_PATH:-agentctl.sh}"

# Optional override to avoid GitHub raw entirely (e.g. pull from S3).
AGENTCTL_URL="${AGENTCTL_URL:-}"

################################################################################
# CONFIG: /srv data disk behavior
################################################################################
# If REQUIRE_DATA_DISK=1 and no data disk is detected, bootstrap will fail.
# If REQUIRE_DATA_DISK=0, bootstrap continues and /srv will remain on the root volume.
REQUIRE_DATA_DISK="${REQUIRE_DATA_DISK:-1}"
DATA_DEVICE_WAIT_SECONDS="${DATA_DEVICE_WAIT_SECONDS:-120}"
DATA_DEVICE_WAIT_INTERVAL="${DATA_DEVICE_WAIT_INTERVAL:-2}"

################################################################################
# CONFIG: desired data device
################################################################################
DATA_DEV_PRIMARY="${DATA_DEV_PRIMARY:-/dev/sdb}"
DATA_DEV_FALLBACKS=(
  "/dev/xvdb"
  "/dev/nvme1n1"
  "/dev/nvme2n1"
)

################################################################################
# CONFIG: optional installs (best effort)
################################################################################
INSTALL_CODEX_CLI="${INSTALL_CODEX_CLI:-1}"
INSTALL_GEMINI_CLI="${INSTALL_GEMINI_CLI:-1}"
INSTALL_CLAUDE_CLI="${INSTALL_CLAUDE_CLI:-1}"

################################################################################
# CONFIG: optional remote config (persist outside instances)
################################################################################
# To enable, set AGENT_HOST_CONFIG_NAME to a non-empty value.
# This lets you have multiple deployments pointing at different shared configs.
#
# Derived defaults when AGENT_HOST_CONFIG_NAME is set:
#   Secrets Manager (Bitbucket SSH private key): agent-host/<name>/bitbucket_ssh_private_key
#   SSM Parameter Store (agentctl repos.txt):    /agent-host/<name>/agentctl/repos_txt
AGENT_HOST_CONFIG_NAME="${AGENT_HOST_CONFIG_NAME:-}"

# Overrides (set these directly if you prefer not to use the derived names).
BITBUCKET_SSH_KEY_SECRET_ID="${BITBUCKET_SSH_KEY_SECRET_ID:-}"
AGENTCTL_REPOS_SSM_PARAM_NAME="${AGENTCTL_REPOS_SSM_PARAM_NAME:-}"

# Optional: Bitbucket MCP credentials secret (for Codex/Gemini/Claude tool integrations).
# Default when AGENT_HOST_CONFIG_NAME is set:
#   agent-host/<name>/bitbucket_mcp_credentials
BITBUCKET_MCP_CREDENTIALS_SECRET_ID="${BITBUCKET_MCP_CREDENTIALS_SECRET_ID:-}"

# Command used by CLIs to start the Bitbucket MCP server locally (stdio) on the instance.
BITBUCKET_MCP_COMMAND="${BITBUCKET_MCP_COMMAND:-npx}"
BITBUCKET_MCP_ARGS=("-y" "bitbucket-mcp@latest")

# If enabled and this is 1, failing to fetch/apply remote config will fail the bootstrap.
REQUIRE_REMOTE_CONFIG="${REQUIRE_REMOTE_CONFIG:-1}"

# Optional region override for AWS CLI calls. If unset, bootstrap will attempt to detect region via IMDS.
REMOTE_CONFIG_AWS_REGION="${REMOTE_CONFIG_AWS_REGION:-}"

raw_url() {
  echo "https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/${GITHUB_REF}/$1"
}

log() { echo "[$(date -Is)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

################################################################################
# 1) Find the data device (prefer /dev/sdb)
################################################################################
find_data_device() {
  # Prefer an explicit mapping first.
  if [[ -n "${DATA_DEV_PRIMARY:-}" && -b "$DATA_DEV_PRIMARY" ]]; then
    echo "$DATA_DEV_PRIMARY"
    return 0
  fi

  for d in "${DATA_DEV_FALLBACKS[@]}"; do
    [[ -b "$d" ]] || continue
    echo "$d"
    return 0
  done

  # Nitro: find first non-root nvme disk (root is usually nvme0n1, data often nvme1n1)
  local root_src root_disk
  root_src="$(findmnt -n -o SOURCE / || true)"
  # root_src could be /dev/nvme0n1p1 -> root_disk /dev/nvme0n1
  root_disk="$(echo "$root_src" | sed -E 's/p?[0-9]+$//')"

  for d in /dev/nvme*n1; do
    [[ -b "$d" ]] || continue
    [[ "$d" == "$root_disk" ]] && continue
    echo "$d"
    return 0
  done

  return 1
}

wait_for_data_device() {
  log "Waiting up to ${DATA_DEVICE_WAIT_SECONDS}s for data device to appear..."

  local loops
  loops=$((DATA_DEVICE_WAIT_SECONDS / DATA_DEVICE_WAIT_INTERVAL))
  [[ "$loops" -lt 1 ]] && loops=1

  for _ in $(seq 1 "$loops"); do
    if find_data_device >/dev/null 2>&1; then
      return 0
    fi
    sleep "$DATA_DEVICE_WAIT_INTERVAL"
  done

  return 1
}

################################################################################
# 2) Mount /srv
################################################################################
mount_srv() {
  if mountpoint -q /srv; then
    log "/srv already mounted"
    return 0
  fi

  mkdir -p /srv

  if ! wait_for_data_device; then
    if [[ "$REQUIRE_DATA_DISK" == "1" ]]; then
      die "No data device detected after waiting ${DATA_DEVICE_WAIT_SECONDS}s. If this instance should have an extra EBS volume, check the launch template / block device mappings."
    fi

    log "WARNING: No data device detected; continuing without mounting /srv (it will remain on the root volume)."
    return 0
  fi

  local disk
  if ! disk="$(find_data_device)"; then
    die "Could not find a data device to mount at /srv (unexpected after wait)."
  fi

  log "Using data disk: $disk"

  # If the disk has partitions, use the first partition; otherwise use the disk itself.
  local target="$disk"
  local part
  part="$(lsblk -nr -o NAME,TYPE "$disk" | awk '$2=="part"{print $1; exit}' || true)"
  if [[ -n "$part" ]]; then
    target="/dev/${part}"
    log "Disk has partitions, using partition: $target"
  fi

  # If target has no filesystem type, create one.
  local fstype
  fstype="$(lsblk -nr -o FSTYPE "$target" | head -n1 | tr -d ' ' || true)"
  if [[ -z "$fstype" ]]; then
    log "No filesystem detected on $target, creating ext4..."
    mkfs.ext4 -F "$target"
  fi

  local uuid
  uuid="$(blkid -s UUID -o value "$target" || true)"
  [[ -n "$uuid" ]] || die "Unable to read filesystem UUID for $target (after mkfs)."

  if ! grep -q "UUID=${uuid} /srv " /etc/fstab; then
    log "Adding /srv mount to /etc/fstab"
    echo "UUID=${uuid} /srv ext4 defaults,nofail 0 2" >> /etc/fstab
  fi

  log "Mounting /srv"
  mount /srv
}

################################################################################
# 3) Base OS packages + agent user
################################################################################
install_awscli() {
  if command -v aws >/dev/null 2>&1; then
    return 0
  fi

  log "Installing AWS CLI (required for remote config if enabled)..."

  # On Ubuntu, awscli is commonly in the 'universe' component.
  if [[ -r /etc/os-release ]] && grep -q '^ID=ubuntu' /etc/os-release; then
    apt-get install -y software-properties-common >/dev/null 2>&1 || true
    if command -v add-apt-repository >/dev/null 2>&1; then
      add-apt-repository -y universe >/dev/null 2>&1 || true
      apt-get update
    fi
  fi

  # Try apt first.
  if apt-get install -y awscli >/dev/null 2>&1; then
    return 0
  fi

  # Fallback: AWS CLI v2 installer (works even when apt lacks awscli).
  local arch pkg
  arch="$(uname -m)"
  case "$arch" in
    x86_64)
      pkg="awscli-exe-linux-x86_64.zip"
      ;;
    aarch64|arm64)
      pkg="awscli-exe-linux-aarch64.zip"
      ;;
    *)
      die "Unsupported architecture for AWS CLI v2 install: $arch"
      ;;
  esac

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  log "Downloading AWS CLI v2 ($pkg)..."
  curl -fsSL --retry 5 --retry-delay 2 --connect-timeout 10 "https://awscli.amazonaws.com/${pkg}" -o "${tmp_dir}/awscliv2.zip"
  unzip -q "${tmp_dir}/awscliv2.zip" -d "$tmp_dir"
  "${tmp_dir}/aws/install" --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update

  rm -rf "$tmp_dir"

  command -v aws >/dev/null 2>&1 || die "AWS CLI install failed"
}
install_base() {
  log "Installing base packages..."

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    tmux git zsh curl ca-certificates gnupg jq unzip ripgrep \
    build-essential python3 python3-pip \
    openssh-client

  install_awscli

  log "Creating agent user (passwordless sudo)..."
  if ! id -u agent >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo agent
  fi

  cat >/etc/sudoers.d/agent <<'EOF'
agent ALL=(ALL) NOPASSWD:ALL
EOF
  chmod 0440 /etc/sudoers.d/agent
}

stat_uid() {
  # Print file uid or empty.
  local p="$1"
  if command -v stat >/dev/null 2>&1; then
    stat -c '%u' "$p" 2>/dev/null || true
  fi
}

stat_mode() {
  # Print file mode (octal perms, e.g. 4755) or empty.
  local p="$1"
  if command -v stat >/dev/null 2>&1; then
    stat -c '%a' "$p" 2>/dev/null || true
  fi
}

repair_sudo_ownership() {
  # Some custom AMIs/snapshots can end up with incorrect ownership on sudo config files.
  # sudo refuses to run unless these are owned by root.
  log "Repairing sudo config ownership (if needed)..."

  # First, fix the sudo binary itself (must be root-owned + setuid).
  # If /usr/bin/sudo loses setuid, sudo will not work regardless of sudoers config.
  if [[ -f /usr/bin/sudo ]]; then
    chown root:root /usr/bin/sudo 2>/dev/null || true
    chmod 4755 /usr/bin/sudo 2>/dev/null || true

    local uid mode
    uid="$(stat_uid /usr/bin/sudo)"
    mode="$(stat_mode /usr/bin/sudo)"
    if [[ -n "${uid:-}" && "$uid" != "0" ]]; then
      log "WARNING: /usr/bin/sudo uid is still $uid (expected 0)"
    fi
    if [[ -n "${mode:-}" && "$mode" != "4755" ]]; then
      log "WARNING: /usr/bin/sudo mode is $mode (expected 4755)"
    fi
  fi

  if [[ -f /etc/sudo.conf ]]; then
    local after
    chown root:root /etc/sudo.conf 2>/dev/null || true
    chmod 0644 /etc/sudo.conf 2>/dev/null || true
    after="$(stat_uid /etc/sudo.conf)"
    if [[ -n "${after:-}" && "$after" != "0" ]]; then
      log "WARNING: /etc/sudo.conf uid is still $after (expected 0)"
    fi
  fi

  if [[ -f /etc/sudoers ]]; then
    local after
    chown root:root /etc/sudoers 2>/dev/null || true
    chmod 0440 /etc/sudoers 2>/dev/null || true
    after="$(stat_uid /etc/sudoers)"
    if [[ -n "${after:-}" && "$after" != "0" ]]; then
      log "WARNING: /etc/sudoers uid is still $after (expected 0)"
    fi
  fi

  if [[ -d /etc/sudoers.d ]]; then
    chown root:root /etc/sudoers.d 2>/dev/null || true
    chmod 0755 /etc/sudoers.d 2>/dev/null || true

    # Fix ownership/perms of sudoers include files too.
    # sudo will refuse to run if any sudoers.d file is not owned by root.
    shopt -s nullglob
    local f
    for f in /etc/sudoers.d/*; do
      [[ -f "$f" ]] || continue
      chown root:root "$f" 2>/dev/null || true
      chmod 0440 "$f" 2>/dev/null || true
      local uid
      uid="$(stat_uid "$f")"
      if [[ -n "${uid:-}" && "$uid" != "0" ]]; then
        log "WARNING: $f uid is still $uid (expected 0)"
      fi
    done
    shopt -u nullglob
  fi

  # Quietly verify sudo usability after repair.
  if command -v sudo >/dev/null 2>&1; then
    sudo -n true >/dev/null 2>&1 || log "WARNING: sudo still failing after ownership repair"
  fi
}

run_as_agent() {
  # Run a command as the 'agent' user in a login shell.
  # Prefer sudo, but fall back to runuser/su if sudo itself is broken.
  if command -v sudo >/dev/null 2>&1; then
    if sudo -n true >/dev/null 2>&1; then
      sudo -i -u agent "$@"
      return $?
    fi
  fi

  if command -v runuser >/dev/null 2>&1; then
    local q=()
    local a
    for a in "$@"; do
      q+=("$(printf '%q' "$a")")
    done
    runuser -l agent -c "${q[*]}"
    return $?
  fi

  # Fallback (should exist on most distros)
  local q=()
  local a
  for a in "$@"; do
    q+=("$(printf '%q' "$a")")
  done
  su - agent -c "${q[*]}"
}

################################################################################
# 4) Install Node 22
################################################################################
install_node() {
  log "Installing Node.js 22..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
}

################################################################################
# 5) Install SSM Agent (best effort)
################################################################################
install_ssm_agent() {
  log "Installing Amazon SSM Agent (best effort) and enabling service..."

  # If it's already present, just ensure it's started.
  if systemctl list-unit-files 2>/dev/null | grep -q '^amazon-ssm-agent\.service'; then
    systemctl enable --now amazon-ssm-agent.service || true
    return 0
  fi

  if command -v snap >/dev/null 2>&1; then
    snap install amazon-ssm-agent --classic || true
    systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true
    return 0
  fi

  # Fallback: some distros/AMIs expose amazon-ssm-agent as an apt package.
  if apt-cache show amazon-ssm-agent >/dev/null 2>&1; then
    apt-get install -y amazon-ssm-agent || { log "WARNING: Failed to install amazon-ssm-agent via apt"; return 0; }
    systemctl enable --now amazon-ssm-agent.service || true
    return 0
  fi

  log "WARNING: snap not found and amazon-ssm-agent apt package not available; skipping SSM install."
}

################################################################################
# 6) Configure npm globals for agent, install CLIs
################################################################################
configure_agent_path() {
  log "Ensuring agent PATH includes ~/.npm-global/bin and ~/.local/bin..."
  cat >/etc/profile.d/agent-paths.sh <<'EOF'
# Agent host PATH additions
if [ -d "$HOME/.npm-global/bin" ]; then
  export PATH="$HOME/.npm-global/bin:$PATH"
fi
if [ -d "$HOME/.local/bin" ]; then
  export PATH="$HOME/.local/bin:$PATH"
fi
EOF
  chmod 0644 /etc/profile.d/agent-paths.sh
}

install_agent_clis() {
  log "Configuring npm global prefix for agent (avoid /usr permission issues)..."
  # If sudo is broken on the base image, still try to proceed using runuser/su.
  run_as_agent bash -lc 'mkdir -p ~/.npm-global && npm config set prefix ~/.npm-global' || log "WARNING: Failed to configure npm global prefix for agent"

  if [[ "$INSTALL_CODEX_CLI" == "1" ]]; then
    log "Installing Codex CLI as agent (best effort)..."
    run_as_agent bash -lc 'npm install -g @openai/codex' || log "WARNING: Codex CLI install failed"
  fi

  if [[ "$INSTALL_GEMINI_CLI" == "1" ]]; then
    log "Installing Gemini CLI as agent (best effort)..."
    run_as_agent bash -lc 'npm install -g @google/gemini-cli' || log "WARNING: Gemini CLI install failed"
  fi

  if [[ "$INSTALL_CLAUDE_CLI" == "1" ]]; then
    log "Installing Claude CLI as agent (best effort)..."
    run_as_agent bash -lc 'curl -fsSL https://claude.ai/install.sh | bash' || log "WARNING: Claude CLI install failed"
  fi
}

################################################################################
# 7) Optional remote config (repos + Bitbucket SSH key)
################################################################################
imds_token() {
  # IMDSv2 token (best effort). If IMDSv2 is not required, this may be empty.
  curl -fsSL -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true
}

imds_get() {
  local path="$1"
  local token
  token="$(imds_token)"
  if [[ -n "${token:-}" ]]; then
    curl -fsSL -H "X-aws-ec2-metadata-token: ${token}" "http://169.254.169.254${path}" 2>/dev/null
  else
    curl -fsSL "http://169.254.169.254${path}" 2>/dev/null
  fi
}

detect_aws_region() {
  if [[ -n "${REMOTE_CONFIG_AWS_REGION:-}" ]]; then
    echo "$REMOTE_CONFIG_AWS_REGION"
    return 0
  fi

  # Prefer standard env vars if present.
  if [[ -n "${AWS_REGION:-}" ]]; then
    echo "$AWS_REGION"
    return 0
  fi
  if [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
    echo "$AWS_DEFAULT_REGION"
    return 0
  fi

  local doc
  doc="$(imds_get /latest/dynamic/instance-identity/document || true)"
  if [[ -z "${doc:-}" ]]; then
    return 1
  fi

  local region

  # jq is installed in install_base(). Prefer it here.
  if command -v jq >/dev/null 2>&1; then
    region="$(echo "$doc" | jq -r '.region // empty' 2>/dev/null || true)"
  else
    region="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("region", ""))' "$doc" 2>/dev/null || true)"
  fi

  if [[ -z "${region:-}" ]]; then
    return 1
  fi

  echo "$region"
  return 0
}

write_agent_bitbucket_key_from_secret() {
  local region="$1"
  local secret_id="$2"

  log "Fetching Bitbucket SSH key from Secrets Manager: $secret_id"

  local secret_bin secret_str
  secret_bin="$(aws --region "$region" secretsmanager get-secret-value \
    --secret-id "$secret_id" \
    --query SecretBinary --output text 2>/dev/null || true)"

  install -d -m 0700 -o agent -g agent /home/agent/.ssh

  if [[ -n "${secret_bin:-}" && "$secret_bin" != "None" ]]; then
    echo "$secret_bin" | base64 -d > /home/agent/.ssh/id_ed25519
  else
    secret_str="$(aws --region "$region" secretsmanager get-secret-value \
      --secret-id "$secret_id" \
      --query SecretString --output text)"
    [[ -n "${secret_str:-}" && "$secret_str" != "None" ]] || return 1
    printf '%s\n' "$secret_str" > /home/agent/.ssh/id_ed25519
  fi

  chown agent:agent /home/agent/.ssh/id_ed25519
  chmod 0600 /home/agent/.ssh/id_ed25519

  # Ensure ssh uses this key for bitbucket.
  if [[ ! -f /home/agent/.ssh/config ]] || ! grep -q "^Host bitbucket\.org$" /home/agent/.ssh/config; then
    cat >>/home/agent/.ssh/config <<'EOF'
Host bitbucket.org
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF
    chown agent:agent /home/agent/.ssh/config
    chmod 0600 /home/agent/.ssh/config
  fi

  # Pre-seed known_hosts to avoid interactive prompts.
  run_as_agent bash -lc 'ssh-keygen -F bitbucket.org >/dev/null 2>&1 || ssh-keyscan -t rsa,ed25519 bitbucket.org >> ~/.ssh/known_hosts' || true
  run_as_agent bash -lc 'chmod 0644 ~/.ssh/known_hosts || true' || true

  return 0
}

write_agent_repos_from_ssm() {
  local region="$1"
  local param_name="$2"

  log "Fetching agentctl repos from SSM Parameter Store: $param_name"

  install -d -m 0755 -o agent -g agent /home/agent/.config/agentctl

  local tmp
  tmp="$(mktemp)"

  if ! aws --region "$region" ssm get-parameter \
    --name "$param_name" \
    --with-decryption \
    --query Parameter.Value --output text \
    >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  mv "$tmp" /home/agent/.config/agentctl/repos.txt
  chown agent:agent /home/agent/.config/agentctl/repos.txt
  chmod 0644 /home/agent/.config/agentctl/repos.txt
  return 0
}

write_agent_bitbucket_mcp_env_from_secret() {
  local region="$1"
  local secret_id="$2"

  log "Fetching Bitbucket MCP credentials from Secrets Manager: $secret_id"

  local secret_json
  secret_json="$(aws --region "$region" secretsmanager get-secret-value \
    --secret-id "$secret_id" \
    --query SecretString --output text 2>/dev/null || true)"

  if [[ -z "${secret_json:-}" || "$secret_json" == "None" ]]; then
    return 1
  fi

  install -d -m 0755 -o agent -g agent /home/agent/.config/agentctl/mcp

  # Write an env file (chmod 600) that will be sourced for the agent user.
  # Expected JSON keys (preferred):
  #   BITBUCKET_WORKSPACE, BITBUCKET_TOKEN
  # Alternative/basic auth keys:
  #   BITBUCKET_USERNAME (or BITBUCKET_EMAIL), BITBUCKET_PASSWORD
  # Optional:
  #   BITBUCKET_URL
  #
  # Write atomically (avoid leaving an empty file if parsing fails).
  local tmp
  tmp="$(mktemp)"

  if ! python3 -c 'import json,sys,shlex
raw = sys.stdin.read()
data = json.loads(raw)

def first(*keys):
    for k in keys:
        if k in data and data[k] not in (None, ""):
            return data[k]
        lk = k.lower()
        if lk in data and data[lk] not in (None, ""):
            return data[lk]
    return None

exports = {}
exports["BITBUCKET_WORKSPACE"] = first("BITBUCKET_WORKSPACE")
exports["BITBUCKET_URL"] = first("BITBUCKET_URL")

# Token-based auth (preferred)
exports["BITBUCKET_TOKEN"] = first("BITBUCKET_TOKEN")

# Basic auth fallback
exports["BITBUCKET_USERNAME"] = first("BITBUCKET_USERNAME", "BITBUCKET_EMAIL", "EMAIL")
exports["BITBUCKET_PASSWORD"] = first("BITBUCKET_PASSWORD")

for k, v in exports.items():
    if v is None:
        continue
    print(f"export {k}={shlex.quote(str(v))}")
' <<<"$secret_json" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  mv -f "$tmp" /home/agent/.config/agentctl/mcp/bitbucket.env
  chown agent:agent /home/agent/.config/agentctl/mcp/bitbucket.env
  chmod 0600 /home/agent/.config/agentctl/mcp/bitbucket.env

  # Source the env file automatically for the agent user on login shells.
  if [[ ! -f /etc/profile.d/agent-mcp.sh ]]; then
    cat >/etc/profile.d/agent-mcp.sh <<'EOF'
# Load per-agent MCP env vars (kept in agent's home with 0600 perms).
# This file contains no secrets.

if [ "$(id -un 2>/dev/null)" = "agent" ] && [ -f "$HOME/.config/agentctl/mcp/bitbucket.env" ]; then
  . "$HOME/.config/agentctl/mcp/bitbucket.env"
fi
EOF
    chmod 0644 /etc/profile.d/agent-mcp.sh
  fi

  return 0
}

configure_bitbucket_mcp_for_agent_clis() {
  # Configure Codex + Gemini to launch the Bitbucket MCP server locally.
  # Credentials are provided via environment variables loaded by /etc/profile.d/agent-mcp.sh.

  # Codex CLI: ~/.codex/config.toml
  install -d -m 0700 -o agent -g agent /home/agent/.codex
  local codex_cfg="/home/agent/.codex/config.toml"
  if [[ ! -f "$codex_cfg" ]]; then
    touch "$codex_cfg"
    chown agent:agent "$codex_cfg"
    chmod 0600 "$codex_cfg"
  fi

  if ! grep -q "^\[mcp_servers\.bitbucket\]$" "$codex_cfg" 2>/dev/null; then
    cat >>"$codex_cfg" <<EOF

[mcp_servers.bitbucket]
command = "${BITBUCKET_MCP_COMMAND}"
args = ["${BITBUCKET_MCP_ARGS[0]}", "${BITBUCKET_MCP_ARGS[1]}"]
# Forward these vars from the current environment into the MCP server process.
env_vars = ["BITBUCKET_WORKSPACE", "BITBUCKET_TOKEN", "BITBUCKET_USERNAME", "BITBUCKET_PASSWORD", "BITBUCKET_URL"]
startup_timeout_sec = 20
EOF
    chown agent:agent "$codex_cfg"
    chmod 0600 "$codex_cfg"
  fi

  # Gemini CLI: ~/.gemini/settings.json
  install -d -m 0700 -o agent -g agent /home/agent/.gemini
  local gemini_cfg="/home/agent/.gemini/settings.json"
  if [[ ! -f "$gemini_cfg" ]]; then
    echo '{}' >"$gemini_cfg"
    chown agent:agent "$gemini_cfg"
    chmod 0600 "$gemini_cfg"
  fi

  tmp="$(mktemp)"
  jq --arg cmd "$BITBUCKET_MCP_COMMAND" \
     --arg a0 "${BITBUCKET_MCP_ARGS[0]}" \
     --arg a1 "${BITBUCKET_MCP_ARGS[1]}" \
     '
      .mcpServers = (.mcpServers // {})
      | .mcpServers.bitbucket = {
          command: $cmd,
          args: [$a0, $a1],
          env: {
            BITBUCKET_WORKSPACE: "${BITBUCKET_WORKSPACE}",
            BITBUCKET_TOKEN: "${BITBUCKET_TOKEN}",
            BITBUCKET_USERNAME: "${BITBUCKET_USERNAME}",
            BITBUCKET_PASSWORD: "${BITBUCKET_PASSWORD}",
            BITBUCKET_URL: "${BITBUCKET_URL}"
          }
        }
     ' "$gemini_cfg" >"$tmp" || { rm -f "$tmp"; return 0; }
  mv "$tmp" "$gemini_cfg"
  chown agent:agent "$gemini_cfg"
  chmod 0600 "$gemini_cfg"

  return 0
}

maybe_load_remote_config() {
  # Disabled unless explicitly enabled.
  if [[ -z "${AGENT_HOST_CONFIG_NAME:-}" && -z "${BITBUCKET_SSH_KEY_SECRET_ID:-}" && -z "${AGENTCTL_REPOS_SSM_PARAM_NAME:-}" ]]; then
    log "Remote config: disabled"
    return 0
  fi

  if [[ -z "${BITBUCKET_SSH_KEY_SECRET_ID:-}" && -n "${AGENT_HOST_CONFIG_NAME:-}" ]]; then
    BITBUCKET_SSH_KEY_SECRET_ID="agent-host/${AGENT_HOST_CONFIG_NAME}/bitbucket_ssh_private_key"
  fi

  if [[ -z "${AGENTCTL_REPOS_SSM_PARAM_NAME:-}" && -n "${AGENT_HOST_CONFIG_NAME:-}" ]]; then
    AGENTCTL_REPOS_SSM_PARAM_NAME="/agent-host/${AGENT_HOST_CONFIG_NAME}/agentctl/repos_txt"
  fi

  if [[ -z "${BITBUCKET_MCP_CREDENTIALS_SECRET_ID:-}" && -n "${AGENT_HOST_CONFIG_NAME:-}" ]]; then
    BITBUCKET_MCP_CREDENTIALS_SECRET_ID="agent-host/${AGENT_HOST_CONFIG_NAME}/bitbucket_mcp_credentials"
  fi

  local region
  if ! region="$(detect_aws_region)"; then
    if [[ "$REQUIRE_REMOTE_CONFIG" == "1" ]]; then
      die "Remote config enabled but AWS region could not be detected (set REMOTE_CONFIG_AWS_REGION or ensure IMDS is available)."
    fi
    log "WARNING: Remote config enabled but region could not be detected; skipping."
    return 0
  fi

  log "Remote config: enabled (region=$region config_name=${AGENT_HOST_CONFIG_NAME:-<custom>})"

  local ok=0

  if [[ -n "${BITBUCKET_SSH_KEY_SECRET_ID:-}" ]]; then
    if write_agent_bitbucket_key_from_secret "$region" "$BITBUCKET_SSH_KEY_SECRET_ID"; then
      ok=1
    else
      if [[ "$REQUIRE_REMOTE_CONFIG" == "1" ]]; then
        die "Failed to load Bitbucket SSH key secret: $BITBUCKET_SSH_KEY_SECRET_ID"
      fi
      log "WARNING: Failed to load Bitbucket SSH key secret: $BITBUCKET_SSH_KEY_SECRET_ID"
    fi
  fi

  if [[ -n "${AGENTCTL_REPOS_SSM_PARAM_NAME:-}" ]]; then
    if write_agent_repos_from_ssm "$region" "$AGENTCTL_REPOS_SSM_PARAM_NAME"; then
      ok=1
    else
      if [[ "$REQUIRE_REMOTE_CONFIG" == "1" ]]; then
        die "Failed to load agentctl repos parameter: $AGENTCTL_REPOS_SSM_PARAM_NAME"
      fi
      log "WARNING: Failed to load agentctl repos parameter: $AGENTCTL_REPOS_SSM_PARAM_NAME"
    fi
  fi

  # Optional Bitbucket MCP config (do not fail the whole bootstrap if missing).
  if [[ -n "${BITBUCKET_MCP_CREDENTIALS_SECRET_ID:-}" ]]; then
    if write_agent_bitbucket_mcp_env_from_secret "$region" "$BITBUCKET_MCP_CREDENTIALS_SECRET_ID"; then
      configure_bitbucket_mcp_for_agent_clis || true
    else
      log "WARNING: Bitbucket MCP credentials secret not loaded: $BITBUCKET_MCP_CREDENTIALS_SECRET_ID"
    fi
  fi

  if [[ "$ok" -eq 1 ]]; then
    log "Remote config applied."

    # Persist the config name for later use (e.g. agentctl sync-config with no args).
    if [[ -n "${AGENT_HOST_CONFIG_NAME:-}" ]]; then
      install -d -m 0755 -o agent -g agent /home/agent/.config/agentctl
      echo "$AGENT_HOST_CONFIG_NAME" > /home/agent/.config/agentctl/remote_config_name
      chown agent:agent /home/agent/.config/agentctl/remote_config_name
      chmod 0644 /home/agent/.config/agentctl/remote_config_name
    fi
  fi

  return 0
}

################################################################################
# 8) Layout under /srv and install agentctl
################################################################################
setup_srv_layout() {
  log "Creating /srv layout..."
  mkdir -p /srv/agents /srv/git-mirrors /srv/agents/conflicts
  chown -R agent:agent /srv
}

install_agentctl() {
  log "Installing agentctl..."

  if [[ "$GITHUB_OWNER" == *"YOUR_"* || "$GITHUB_REPO" == *"YOUR_"* ]]; then
    die "GITHUB_OWNER/GITHUB_REPO are still placeholders. Set them to a real repo or provide AGENTCTL_URL."
  fi

  local url
  if [[ -n "$AGENTCTL_URL" ]]; then
    url="$AGENTCTL_URL"
  else
    url="$(raw_url "$AGENTCTL_PATH")"
  fi

  log "Downloading agentctl from: $url"
  curl -fsSL --retry 5 --retry-delay 2 --connect-timeout 10 "$url" -o /usr/local/bin/agentctl
  chmod 0755 /usr/local/bin/agentctl
}

seed_config_files() {
  log "Creating global context + repos file placeholders (if missing)..."

  if [[ ! -f /srv/agents/CONTEXT.md ]]; then
    cat >/srv/agents/CONTEXT.md <<'EOF'
# Agent Host Global Context

Edit this file after provisioning.
EOF
    chown agent:agent /srv/agents/CONTEXT.md
  fi

  install -d -m 0755 /home/agent/.config/agentctl
  if [[ ! -f /home/agent/.config/agentctl/repos.txt ]]; then
    cat >/home/agent/.config/agentctl/repos.txt <<'EOF'
# repo_name  git_url
# acquire-backend  git@bitbucket.org:YOUR_ORG/acquire-backend.git
EOF
    chown -R agent:agent /home/agent/.config
  fi
}

################################################################################
# 8) Sanity checks
################################################################################
sanity_checks() {
  log "Sanity checks..."

  # Ensure sudo config is sane before we suggest using sudo interactively.
  repair_sudo_ownership

  run_as_agent bash -lc 'command -v codex && codex --help >/dev/null || true' || true
  run_as_agent bash -lc 'command -v gemini && gemini --help >/dev/null || true' || true
  run_as_agent bash -lc 'command -v claude && claude --help >/dev/null || true' || true
  command -v agentctl >/dev/null 2>&1 || die "agentctl not found after install"

  log "Done."
  log "Next: sudo -i -u agent (or: su - agent if sudo is broken)"
  log "Then: agentctl session"
  log "Note: If arrow keys print ^[[A in SSM Session Manager, that's because SSM defaults to /bin/sh." 
  log "      Fix is an AWS Session Manager preference (account+region). See: scripts/configure_ssm_shell_profile.sh in this repo."
}

################################################################################
# MAIN
################################################################################
main() {
  mount_srv
  install_base

  # Ensure sudo works before we use it to run any "as agent" steps.
  # (We also fall back to runuser/su when sudo is broken.)
  repair_sudo_ownership

  # Optional: pull shared config (Bitbucket key + repos list) from AWS so it persists across instances.
  maybe_load_remote_config

  install_node
  install_ssm_agent
  configure_agent_path
  setup_srv_layout
  install_agentctl
  seed_config_files
  install_agent_clis
  sanity_checks
}

main "$@"

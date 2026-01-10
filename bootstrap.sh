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
install_base() {
  log "Installing base packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    tmux git zsh curl ca-certificates gnupg jq unzip ripgrep \
    build-essential python3 python3-pip

  log "Creating agent user (passwordless sudo)..."
  if ! id -u agent >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo agent
  fi

  cat >/etc/sudoers.d/agent <<'EOF'
agent ALL=(ALL) NOPASSWD:ALL
EOF
  chmod 0440 /etc/sudoers.d/agent
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
  sudo -i -u agent bash -lc 'mkdir -p ~/.npm-global && npm config set prefix ~/.npm-global' || log "WARNING: Failed to configure npm global prefix for agent"

  if [[ "$INSTALL_CODEX_CLI" == "1" ]]; then
    log "Installing Codex CLI as agent (best effort)..."
    sudo -i -u agent bash -lc 'npm install -g @openai/codex' || log "WARNING: Codex CLI install failed"
  fi

  if [[ "$INSTALL_GEMINI_CLI" == "1" ]]; then
    log "Installing Gemini CLI as agent (best effort)..."
    sudo -i -u agent bash -lc 'npm install -g @google/gemini-cli' || log "WARNING: Gemini CLI install failed"
  fi

  if [[ "$INSTALL_CLAUDE_CLI" == "1" ]]; then
    log "Installing Claude CLI as agent (best effort)..."
    sudo -i -u agent bash -lc 'curl -fsSL https://claude.ai/install.sh | bash' || log "WARNING: Claude CLI install failed"
  fi
}

################################################################################
# 7) Layout under /srv and install agentctl
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
  sudo -i -u agent bash -lc 'command -v codex && codex --help >/dev/null || true'
  sudo -i -u agent bash -lc 'command -v gemini && gemini --help >/dev/null || true'
  sudo -i -u agent bash -lc 'command -v claude && claude --help >/dev/null || true'
  command -v agentctl >/dev/null 2>&1 || die "agentctl not found after install"

  log "Done."
  log "Next: sudo -i -u agent"
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

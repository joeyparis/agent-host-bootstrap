#!/usr/bin/env bash
set -euo pipefail

# Change these two lines to your repo
GITHUB_OWNER="YOUR_GITHUB_USER_OR_ORG"
GITHUB_REPO="agent-host-bootstrap"
GITHUB_REF="main"

raw() {
  echo "https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/${GITHUB_REF}/$1"
}

log() { echo "[$(date -Is)] $*"; }

log "Installing base packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  tmux git zsh curl ca-certificates gnupg jq unzip ripgrep \
  build-essential python3 python3-pip awscli

log "Creating agent user (passwordless sudo)..."
if ! id -u agent >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo agent
fi
cat >/etc/sudoers.d/agent <<'EOF'
agent ALL=(ALL) NOPASSWD:ALL
EOF
chmod 0440 /etc/sudoers.d/agent

log "Creating base directories..."
mkdir -p /srv/agents /srv/git-mirrors /srv/agents/conflicts
chown -R agent:agent /srv

log "Installing Node.js 22..."
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

log "Configuring npm global prefix for agent (avoid /usr permission issues)..."
sudo -i -u agent bash -lc 'mkdir -p ~/.npm-global && npm config set prefix ~/.npm-global'

log "Ensuring agent PATH includes ~/.npm-global/bin and ~/.local/bin..."
install -d -m 0755 /etc/profile.d
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

log "Installing Amazon SSM Agent (snap) and starting it..."
# Ubuntu typical path; safe if snap already exists
if command -v snap >/dev/null 2>&1; then
  snap install amazon-ssm-agent --classic || true
  systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true
else
  log "WARNING: snap not found. If SSM is required, install snapd or use the .deb method."
fi

log "Installing Codex CLI (npm)..."
sudo -i -u agent bash -lc 'npm install -g @openai/codex'  # :contentReference[oaicite:0]{index=0}

log "Installing Gemini CLI (npm)..."
sudo -i -u agent bash -lc 'npm install -g @google/gemini-cli'  # :contentReference[oaicite:1]{index=1}

log "Installing Claude Code (curl installer)..."
sudo -i -u agent bash -lc 'curl -fsSL https://claude.ai/install.sh | bash'  # :contentReference[oaicite:2]{index=2}

log "Installing agentctl from GitHub..."
curl -fsSL "$(raw agentctl)" -o /usr/local/bin/agentctl
chmod 0755 /usr/local/bin/agentctl

log "Creating global context + repos file placeholders..."
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

log "Sanity checks..."
sudo -i -u agent bash -lc 'command -v codex && codex --help >/dev/null || true'
sudo -i -u agent bash -lc 'command -v gemini && gemini --help >/dev/null || true'
sudo -i -u agent bash -lc 'command -v claude && claude --help >/dev/null || true'
sudo -i -u agent bash -lc 'command -v agentctl && agentctl ps || true'

log "DONE."

#!/usr/bin/env bash
set -euo pipefail

SESSION="agents"
BASE="/srv/agents"
MIRRORS="/srv/git-mirrors"
REPO_FILE="${HOME}/.config/agentctl/repos.txt"

usage() {
  cat <<EOF
Usage:
  agentctl session
  agentctl ps
  agentctl create-agent <agent_name>
  agentctl start <agent_name>
  agentctl worktree <agent_name> <repo_name> <branch_name>
  agentctl list-repos
  agentctl list-agents
  agentctl delete <agent_name> [--force]
  agentctl rename <old_name> <new_name>
  agentctl refresh-context [agent_name] [repo_name]
  agentctl sync-config [config_name] [--region <aws_region>]
EOF
}

REQUIRE_USER="agent"
MODE="${AGENTCTL_USER_MODE:-auto}"  # auto | strict

ensure_agent_user() {
  local current
  current="$(id -un)"

  if [[ "$current" == "$REQUIRE_USER" ]]; then
    return 0
  fi

  case "$MODE" in
    strict)
      echo "agentctl must be run as '$REQUIRE_USER' (current user: '$current')." >&2
      echo "Run: sudo -i -u $REQUIRE_USER" >&2
      exit 1
      ;;
    auto)
      # Re-exec ourselves as agent using a login shell so HOME/PATH are correct
      exec sudo -i -u "$REQUIRE_USER" /usr/local/bin/agentctl "$@"
      ;;
    *)
      echo "Invalid AGENTCTL_USER_MODE: $MODE (use 'auto' or 'strict')" >&2
      exit 1
      ;;
  esac
}

ensure_session() {
  # Force bash login shells in tmux so readline/history and arrow keys work.
  # tmux defaults to /bin/sh if not configured, which will echo escape sequences like ^[[A.
  tmux set-option -g default-shell /bin/bash 2>/dev/null || true
  tmux set-option -g default-command "/bin/bash -l" 2>/dev/null || true

  tmux has-session -t "$SESSION" 2>/dev/null || tmux new-session -d -s "$SESSION" -n "hub" /bin/bash -l

  # Ensure tmux server/session inherits the current PATH (helps when CLIs are installed under ~/.npm-global).
  tmux set-environment -t "$SESSION" PATH "$PATH" 2>/dev/null || true
  tmux set-environment -t "$SESSION" SHELL /bin/bash 2>/dev/null || true
}

agent_paths() {
  local agent_name="$1"
  echo "${BASE}/${agent_name}"
}

write_agent_context_files() {
  local agent_name="$1"
  local repo_root="$2"
  local global_ctx="/srv/agents/CONTEXT.md"
  local agent_ctx="/srv/agents/${agent_name}/AGENT.md"

  if [[ ! -d "$repo_root" ]]; then
    echo "Skipping context write (missing repo dir): $repo_root" >&2
    return 1
  fi
  if [[ ! -f "$global_ctx" ]]; then
    echo "Skipping context write (missing global context): $global_ctx" >&2
    return 1
  fi
  if [[ ! -f "$agent_ctx" ]]; then
    echo "Skipping context write (missing agent context): $agent_ctx" >&2
    return 1
  fi

  local tmp
  tmp="$(mktemp)"

  {
    echo "# Auto-generated. Do not edit in-place."
    echo "# Source of truth:"
    echo "#   ${global_ctx}"
    echo "#   ${agent_ctx}"
    echo
    cat "$global_ctx"
    echo
    echo "----"
    echo
    cat "$agent_ctx"
    echo
  } >"$tmp"

  cp -f "$tmp" "${repo_root}/AGENTS.md"
  cp -f "$tmp" "${repo_root}/CLAUDE.md"
  cp -f "$tmp" "${repo_root}/GEMINI.md"

  rm -f "$tmp"
  return 0
}

refresh_context() {
  # Usage:
  #   agentctl refresh-context               # all agents, all repos
  #   agentctl refresh-context agent01       # one agent, all repos
  #   agentctl refresh-context agent01 repo  # one agent, one repo
  local agent_name="${1:-}"
  local repo_name="${2:-}"

  local agents=()
  if [[ -n "$agent_name" ]]; then
    agents=("$agent_name")
  else
    [[ -d "$BASE" ]] || { echo "No agents directory: $BASE"; return 0; }
    while IFS= read -r a; do
      [[ -n "$a" ]] && agents+=("$a")
    done < <(ls -1 "$BASE" 2>/dev/null || true)
  fi

  local updated=0
  for a in "${agents[@]}"; do
    local root
    root="$(agent_paths "$a")"
    local work_root="${root}/work"

    [[ -d "$work_root" ]] || continue

    if [[ -n "$repo_name" ]]; then
      local repo_dir="${work_root}/${repo_name}"
      # In git worktrees, .git is commonly a FILE (gitdir pointer), not a directory.
      if [[ -e "$repo_dir/.git" ]]; then
        if write_agent_context_files "$a" "$repo_dir"; then
          updated=$((updated+1))
        fi
      else
        echo "Skipping (not a git worktree): $repo_dir"
      fi
      continue
    fi

    shopt -s nullglob
    for repo_dir in "$work_root"/*; do
      [[ -e "$repo_dir/.git" ]] || continue
      if write_agent_context_files "$a" "$repo_dir"; then
        updated=$((updated+1))
      fi
    done
  done

echo "Refreshed context in $updated repo worktrees."
}

remote_config_name_file() {
  echo "${HOME}/.config/agentctl/remote_config_name"
}

detect_aws_region() {
  local forced_region="${1:-}"
  if [[ -n "${forced_region:-}" ]]; then
    echo "$forced_region"
    return 0
  fi

  if [[ -n "${AWS_REGION:-}" ]]; then
    echo "$AWS_REGION"
    return 0
  fi
  if [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
    echo "$AWS_DEFAULT_REGION"
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi

  local doc
  doc="$(curl -fsSL http://169.254.169.254/latest/dynamic/instance-identity/document 2>/dev/null || true)"
  [[ -n "${doc:-}" ]] || return 1

  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY' <<<"$doc"
import json,sys
print(json.load(sys.stdin)["region"])
PY
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    echo "$doc" | jq -r '.region'
    return 0
  fi

  return 1
}

sync_config() {
  # Usage:
  #   agentctl sync-config
  #   agentctl sync-config <config_name>
  #   agentctl sync-config <config_name> --region us-east-1

  local config_name=""
  local region=""

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --region)
        region="$2"; shift 2 ;;
      -h|--help)
        usage; return 0 ;;
      *)
        if [[ -z "$config_name" ]]; then
          config_name="$1"; shift 1
        else
          echo "Unknown arg: $1" >&2
          usage
          return 2
        fi
        ;;
    esac
  done

  if [[ -z "${config_name:-}" ]]; then
    # Try to read last-used name
    local name_file
    name_file="$(remote_config_name_file)"
    if [[ -f "$name_file" ]]; then
      config_name="$(cat "$name_file" | tr -d ' \t\n\r')"
    fi
  fi

  if [[ -z "${config_name:-}" && -n "${AGENT_HOST_CONFIG_NAME:-}" ]]; then
    config_name="$AGENT_HOST_CONFIG_NAME"
  fi

  if [[ -z "${config_name:-}" ]]; then
    echo "Missing config name." >&2
    echo "Provide one: agentctl sync-config <config_name>" >&2
    return 2
  fi

  if ! command -v aws >/dev/null 2>&1; then
    echo "aws CLI not found. Install awscli (bootstrap installs it)." >&2
    return 1
  fi

  if ! region="$(detect_aws_region "$region")"; then
    echo "Could not detect AWS region (pass --region or set AWS_REGION)." >&2
    return 1
  fi

  local secret_id="agent-host/${config_name}/bitbucket_ssh_private_key"
  local param_name="/agent-host/${config_name}/agentctl/repos_txt"

  echo "Syncing remote config: name=$config_name region=$region"

  mkdir -p "${HOME}/.ssh" "${HOME}/.config/agentctl"
  chmod 0700 "${HOME}/.ssh" || true

  # 1) Fetch and write the Bitbucket SSH private key.
  local secret_bin secret_str
  secret_bin="$(aws --region "$region" secretsmanager get-secret-value \
    --secret-id "$secret_id" \
    --query SecretBinary --output text 2>/dev/null || true)"

  if [[ -n "${secret_bin:-}" && "$secret_bin" != "None" ]]; then
    if command -v base64 >/dev/null 2>&1; then
      echo "$secret_bin" | base64 -d >"${HOME}/.ssh/id_ed25519"
    else
      python3 - <<'PY' <<<"$secret_bin" >"${HOME}/.ssh/id_ed25519"
import base64,sys
sys.stdout.buffer.write(base64.b64decode(sys.stdin.read().strip()))
PY
    fi
  else
    secret_str="$(aws --region "$region" secretsmanager get-secret-value \
      --secret-id "$secret_id" \
      --query SecretString --output text)"
    [[ -n "${secret_str:-}" && "$secret_str" != "None" ]] || { echo "Failed to read secret: $secret_id" >&2; return 1; }
    printf '%s\n' "$secret_str" >"${HOME}/.ssh/id_ed25519"
  fi

  chmod 0600 "${HOME}/.ssh/id_ed25519"

  # Ensure ssh uses this key for Bitbucket.
  if [[ ! -f "${HOME}/.ssh/config" ]] || ! grep -q "^Host bitbucket\.org$" "${HOME}/.ssh/config"; then
    cat >>"${HOME}/.ssh/config" <<'EOF'
Host bitbucket.org
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF
    chmod 0600 "${HOME}/.ssh/config" || true
  fi

  # Seed known_hosts to avoid prompts.
  ssh-keygen -F bitbucket.org >/dev/null 2>&1 || ssh-keyscan -t rsa,ed25519 bitbucket.org >> "${HOME}/.ssh/known_hosts" 2>/dev/null || true
  chmod 0644 "${HOME}/.ssh/known_hosts" 2>/dev/null || true

  # 2) Fetch and write repos.txt.
  aws --region "$region" ssm get-parameter \
    --name "$param_name" \
    --with-decryption \
    --query Parameter.Value --output text \
    >"${HOME}/.config/agentctl/repos.txt"

  chmod 0644 "${HOME}/.config/agentctl/repos.txt" || true

  # 3) Persist last-used config name for convenience.
  echo "$config_name" >"$(remote_config_name_file)"
  chmod 0644 "$(remote_config_name_file)" || true

  echo "Synced:"
  echo "  - SSH key: ${HOME}/.ssh/id_ed25519 (from $secret_id)"
  echo "  - repos:   ${HOME}/.config/agentctl/repos.txt (from $param_name)"
  return 0
}

list_repos() {
  if [[ ! -f "$REPO_FILE" ]]; then
    echo "Missing repo file: $REPO_FILE"
    exit 1
  fi
  awk 'NF >= 2 && $1 !~ /^#/' "$REPO_FILE" | awk '{print $1}'
}

repo_url() {
  local repo_name="$1"
  awk -v r="$repo_name" 'NF>=2 && $1==r {print $2}' "$REPO_FILE"
}

create_agent() {
  local agent_name="$1"
  local root
  root="$(agent_paths "$agent_name")"
  mkdir -p "$root/work" "$root/logs"

  # Ensure every agent has a per-agent overlay file.
  # This file is combined with /srv/agents/CONTEXT.md when generating:
  #   AGENTS.md, CLAUDE.md, GEMINI.md in each repo worktree root.
  local agent_ctx="${root}/AGENT.md"
  if [[ ! -f "$agent_ctx" ]]; then
    cat >"$agent_ctx" <<EOF
# Agent: ${agent_name}

This file is the per-agent overlay. It is combined with:
- /srv/agents/CONTEXT.md (global host context)

Generated instruction files are written into each repo worktree root as:
- AGENTS.md (Codex)
- CLAUDE.md (Claude)
- GEMINI.md (Gemini)

## Responsibilities
- General purpose coding agent unless the user assigns a narrower scope.

## Operating rules
- Work only inside: ${root}/work/<repo>
- Prefer small commits and clear messages
- Ask for confirmation before destructive actions, infra changes, migrations, or data backfills
- Coordinate conflicts via: /srv/agents/conflicts
EOF
    chown agent:agent "$agent_ctx" 2>/dev/null || true
  fi

  echo "Created: $root"
}

ensure_context_links() {
  local agent_name="$1"
  local root
  root="$(agent_paths "$agent_name")"

  local work_dir="$root/work"
  local global_ctx="/srv/agents/CONTEXT.md"
  local agent_ctx="/srv/agents/${agent_name}/AGENT.md"

  mkdir -p "$work_dir"

  # Link global context
  if [[ -f "$global_ctx" ]]; then
    ln -sfn "$global_ctx" "$work_dir/HOST_CONTEXT.md"
  fi

  # Link agent context
  if [[ -f "$agent_ctx" ]]; then
    ln -sfn "$agent_ctx" "$work_dir/AGENT_CONTEXT.md"
  fi
}

start_agent() {
  local agent_name="$1"
  ensure_session
  create_agent "$agent_name" >/dev/null

  local root
  root="$(agent_paths "$agent_name")"

  
  ensure_context_links "$agent_name"

  # Create window if missing, otherwise select it
  if tmux list-windows -t "$SESSION" -F '#W' | grep -qx "$agent_name"; then
    tmux select-window -t "${SESSION}:${agent_name}"
  else
    tmux new-window -t "$SESSION" -n "$agent_name" -c "$root/work" /bin/bash -l
  fi

  # Force correct window name even if it existed with a different name
  tmux rename-window -t "${SESSION}:$(tmux display-message -p -t "$SESSION" '#I')" "$agent_name" 2>/dev/null || true

  # Set default path for that window so new panes open in the workspace
  tmux set-option -t "${SESSION}:${agent_name}" -w default-path "$root/work" 2>/dev/null || true

  # Drop user into the workspace with a helpful prompt
  tmux send-keys -t "${SESSION}:${agent_name}" "cd '$root/work'" C-m
  tmux send-keys -t "${SESSION}:${agent_name}" "echo 'Workspace: $root'" C-m
  tmux send-keys -t "${SESSION}:${agent_name}" "echo 'Host context: /srv/agents/CONTEXT.md'" C-m
  tmux send-keys -t "${SESSION}:${agent_name}" "echo 'Agent context: /srv/agents/${agent_name}/AGENT.md'" C-m
}

create_worktree() {
  local agent_name="$1"
  local repo_name="$2"
  local branch_name="$3"

  create_agent "$agent_name" >/dev/null
  local root mirror workdir
  root="$(agent_paths "$agent_name")"
  mirror="${MIRRORS}/${repo_name}.git"
  workdir="${root}/work/${repo_name}"

  if [[ ! -d "$mirror" ]]; then
    local url
    url="$(repo_url "$repo_name" || true)"
    if [[ -z "${url:-}" ]]; then
      echo "Unknown repo: $repo_name (add it to $REPO_FILE)"
      exit 1
    fi
    echo "Mirror missing, creating: $repo_name"
    git clone --mirror "$url" "$mirror"
  else
    # Keep mirror fresh enough for normal use
    git -C "$mirror" remote update --prune
  fi

  # If workdir already exists, do nothing
  # In git worktrees, .git is commonly a FILE (gitdir pointer), not a directory.
  if [[ -e "$workdir/.git" || -d "$workdir" ]]; then
    echo "Worktree already exists: $workdir"
    return 0
  fi

  # Ensure branch exists in mirror namespace, base off origin/main if present, else origin/master
  # Pick a sane base ref inside a mirror/bare repo.
  # Mirrors often have refs as refs/heads/* rather than refs/remotes/origin/*.
  local candidates=(
    "refs/heads/main"
    "refs/heads/master"
    "refs/heads/develop"
    "refs/remotes/origin/main"
    "refs/remotes/origin/master"
    "refs/remotes/origin/develop"
  )

  local base_ref=""
  for c in "${candidates[@]}"; do
    if git -C "$mirror" show-ref --quiet "$c"; then
      base_ref="$c"
      break
    fi
  done

  if [[ -z "$base_ref" ]]; then
    echo "Could not find a base branch (main/master/develop) in $repo_name mirror."
    echo "Run: git -C '$mirror' show-ref --heads | head"
    exit 1
  fi


  echo "Creating worktree: agent=$agent_name repo=$repo_name branch=$branch_name"
  git -C "$mirror" worktree add -B "$branch_name" "$workdir" "$base_ref"

  echo "Worktree ready: $workdir"

  write_agent_context_files "$agent_name" "$workdir" || true
}

list_agents() {
  [[ -d "$BASE" ]] || exit 0
  ls -1 "$BASE" 2>/dev/null || true
}

ps_agents() {
  # If tmux server is not running, say so and exit cleanly
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "tmux session '$SESSION' is not running"
    return 0
  fi

  echo "tmux session: $SESSION"
  echo

  # List tmux windows and what is running in the active pane of each window
  tmux list-windows -t "$SESSION" -F 'window=#{window_name} index=#{window_index} active=#{?window_active,yes,no} panes=#{window_panes} cwd=#{pane_current_path} cmd=#{pane_current_command}' \
    | sort
  echo

  echo "agent workspaces on disk:"

  # Build a set of live window names
  live_windows="$(tmux list-windows -t "$SESSION" -F '#W' | tr '\n' ' ')"

  if [[ -d "$BASE" ]]; then
    for d in "$BASE"/*; do
      [[ -d "$d" ]] || continue
      agent_name="$(basename "$d")"
      work_count="$(find "$d/work" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"

      status="disk-only"
      if [[ " $live_windows " == *" $agent_name "* ]]; then
        status="tmux-live"
      fi

      echo "  $agent_name status=$status worktrees=$work_count path=$d"
    done
  fi
}

agent_exists_on_disk() {
  local agent_name="$1"
  [[ -d "${BASE}/${agent_name}" ]]
}

tmux_window_exists() {
  local window_name="$1"
  tmux has-session -t "$SESSION" 2>/dev/null || return 1
  tmux list-windows -t "$SESSION" -F '#W' 2>/dev/null | grep -qx "$window_name"
}

kill_tmux_window_if_exists() {
  local window_name="$1"
  if tmux_window_exists "$window_name"; then
    tmux kill-window -t "${SESSION}:${window_name}"
  fi
}

prune_all_mirror_worktrees() {
  # Prune stale worktree references in all mirrors
  if [[ -d "$MIRRORS" ]]; then
    for repo in "$MIRRORS"/*.git; do
      [[ -d "$repo" ]] || continue
      git -C "$repo" worktree prune >/dev/null 2>&1 || true
    done
  fi
}

delete_agent() {
  local agent_name="$1"
  local force="${2:-}"

  if [[ "$agent_name" == "hub" || "$agent_name" == "ctrl" ]]; then
    echo "Refusing to delete reserved window '$agent_name'." >&2
    exit 1
  fi

  local agent_dir="${BASE}/${agent_name}"

  if [[ "$force" != "--force" ]]; then
    if ! agent_exists_on_disk "$agent_name" && ! tmux_window_exists "$agent_name"; then
      echo "No such agent on disk or in tmux: $agent_name"
      return 0
    fi

    echo "This will delete agent '$agent_name':"
    [[ -d "$agent_dir" ]] && echo "  - Remove directory: $agent_dir"
    tmux_window_exists "$agent_name" && echo "  - Kill tmux window: ${SESSION}:${agent_name}"
    printf "Type the agent name to confirm: "
    read -r confirm
    if [[ "$confirm" != "$agent_name" ]]; then
      echo "Cancelled."
      exit 1
    fi
  fi

  kill_tmux_window_if_exists "$agent_name"

  if [[ -d "$agent_dir" ]]; then
    rm -rf "$agent_dir"
  fi

  prune_all_mirror_worktrees
  echo "Deleted agent: $agent_name"
}

rename_agent() {
  local old_name="$1"
  local new_name="$2"

  if [[ "$old_name" == "hub" || "$old_name" == "ctrl" || "$new_name" == "hub" || "$new_name" == "ctrl" ]]; then
    echo "Refusing to rename from/to reserved name (hub/ctrl)." >&2
    exit 1
  fi

  if [[ "$old_name" == "$new_name" ]]; then
    echo "Old and new names are the same."
    return 0
  fi

  local old_dir="${BASE}/${old_name}"
  local new_dir="${BASE}/${new_name}"

  if [[ -e "$new_dir" ]]; then
    echo "Target agent name already exists on disk: $new_dir" >&2
    exit 1
  fi

  # Rename tmux window if present
  if tmux_window_exists "$old_name"; then
    if tmux_window_exists "$new_name"; then
      echo "Target tmux window name already exists: ${SESSION}:${new_name}" >&2
      exit 1
    fi
    tmux rename-window -t "${SESSION}:${old_name}" "$new_name"
    # Update default-path to new location if we end up moving it
    tmux set-option -t "${SESSION}:${new_name}" -w default-path "${BASE}/${new_name}/work" 2>/dev/null || true
  fi

  # Rename workspace directory if present
  if [[ -d "$old_dir" ]]; then
    mv "$old_dir" "$new_dir"
  else
    echo "Warning: no workspace directory found for '$old_name' at $old_dir"
  fi

  echo "Renamed agent: $old_name -> $new_name"
}


ensure_agent_user "$@"

cmd="${1:-}"
case "$cmd" in
  session)
    ensure_session
    tmux attach -t "$SESSION"
    ;;
  create-agent)
    [[ $# -eq 2 ]] || usage
    create_agent "$2"
    ;;
  start)
    [[ $# -eq 2 ]] || usage
    start_agent "$2"
    tmux attach -t "$SESSION"
    ;;
  worktree)
    [[ $# -eq 4 ]] || usage
    create_worktree "$2" "$3" "$4"
    ;;
  list-repos)
    list_repos
    ;;
  list-agents)
    list_agents
    ;;
  ps)
    ps_agents
    ;;
  delete)
    [[ $# -ge 2 && $# -le 3 ]] || usage
    delete_agent "$2" "${3:-}"
    ;;
  rename)
    [[ $# -eq 3 ]] || usage
    rename_agent "$2" "$3"
    ;;
  refresh-context)
    [[ $# -le 3 ]] || usage
    refresh_context "${2:-}" "${3:-}"
    ;;
  sync-config)
    # agentctl sync-config [config_name] [--region us-east-1]
    shift
    sync_config "$@"
    ;;
  *)
    usage
    ;;
esac

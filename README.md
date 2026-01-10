# agent-host-bootstrap
This repo contains a hardened EC2 user-data bootstrap script (`bootstrap.sh`) and a small host control tool (`agentctl.sh`) for provisioning a Linux “agent host” with:
- `/srv` mounted on a dedicated data volume (when present)
- an `agent` user (passwordless sudo)
- Node.js + optional agent CLIs
- a tmux-based workspace layout under `/srv/agents`

## What’s in this repo
- `bootstrap.sh`
  - Intended to run as EC2 user-data (cloud-init).
  - Debian/Ubuntu oriented (uses `apt-get`).
- `agentctl.sh`
  - Installed onto the instance as `/usr/local/bin/agentctl`.
  - Creates/attaches a tmux session and manages agent workspaces under `/srv/agents`.
- `scripts/configure_ssm_shell_profile.sh`
  - Helper for AWS Systems Manager Session Manager shell behavior (see “SSM arrow keys / history fix”).

## Quick start (EC2 user-data)
1) Use an Ubuntu/Debian AMI.
2) Ensure outbound HTTPS is available during boot (apt, NodeSource, GitHub raw, npm).
3) Provide an additional EBS volume if you want `/srv` mounted on a data disk.
4) Set `bootstrap.sh` as your user-data (or curl it from your repo and execute it).

On first boot, the instance should:
- mount `/srv` (if a data disk is detected)
- install packages
- install Node.js
- install and configure `agentctl`

## Troubleshooting (cloud-init)
On the instance:
```bash
sudo tail -n 200 /var/log/cloud-init-output.log
sudo tail -n 200 /var/log/cloud-init.log
```

## Configuration
### agentctl download source
`bootstrap.sh` installs `agentctl` by downloading `agentctl.sh` from a repo ref.

Options:
- Pin to a specific commit SHA for deterministic builds:
  - `GITHUB_REF=<commit_sha>`
- Bypass GitHub raw entirely and use a custom URL:
  - `AGENTCTL_URL=https://.../agentctl.sh`

### /srv data volume behavior
`bootstrap.sh` will wait briefly for the data disk to appear (to avoid the common “device not ready” race).

Environment variables:
- `REQUIRE_DATA_DISK` (default: `1`)
  - `1`: fail boot if no data disk is detected.
  - `0`: continue boot without mounting `/srv` (it stays on the root volume).
- `DATA_DEVICE_WAIT_SECONDS` (default: `120`)
- `DATA_DEVICE_WAIT_INTERVAL` (default: `2`)
- `DATA_DEV_PRIMARY` (default: `/dev/sdb`)

### Optional agent CLI installs
These are best-effort installs (failures won’t kill the whole bootstrap).

Environment variables:
- `INSTALL_CODEX_CLI` (default: `1`)
- `INSTALL_GEMINI_CLI` (default: `1`)
- `INSTALL_CLAUDE_CLI` (default: `1`)

## Using agentctl
After provisioning:
```bash
sudo -i -u agent
agentctl session
```

Common commands:
```bash
agentctl ps
agentctl create-agent <agent_name>
agentctl start <agent_name>
agentctl list-agents
agentctl list-repos
```

Notes:
- `agentctl` is designed to run as the `agent` user.
- tmux windows created by `agentctl` run `bash -l` to ensure readline/history and arrow keys work reliably.

### tmux quick reference
`agentctl` uses tmux to manage a single session (default name: `agents`) with one window per agent.

By default, tmux uses the prefix key `Ctrl-b` (written below as `C-b`).

Window navigation:
- `C-b c` create a new window
- `C-b n` next window
- `C-b p` previous window
- `C-b <number>` go to window by index
- `C-b w` list windows (interactive picker)
- `C-b ,` rename current window

Pane navigation:
- `C-b %` split pane left/right
- `C-b "` split pane top/bottom
- `C-b o` cycle panes
- `C-b <arrow>` move between panes
- `C-b x` close (kill) the current pane

Session control:
- `C-b d` detach (leave tmux running)
- `tmux attach -t agents` re-attach later

## SSM arrow keys / history fix (Session Manager)
Symptom in an SSM Session Manager shell:
- pressing Up Arrow prints `^[[A`
- Left Arrow prints `^[[D`

Cause:
- Session Manager commonly starts sessions in `/bin/sh`, which does not provide readline-style line editing.

Fix:
- Configure Session Manager Preferences to start `bash` (or another interactive shell).

Important:
- This is a GLOBAL AWS setting scoped to your AWS account + region (for example: `us-east-1`).
- It is not an instance-local setting. Changing instance bootstrap alone will not change the default shell that Session Manager launches.

### Helper script
This repo includes a helper to update the Session Manager preferences document (`SSM-SessionManagerRunShell`) in a region:

```bash
./scripts/configure_ssm_shell_profile.sh --region us-east-1
```

With an AWS named profile:
```bash
./scripts/configure_ssm_shell_profile.sh --region us-east-1 --profile <profile>
```

After running it, open a new SSM session and verify:
```bash
echo "shell=$0 flags=$-"
```
You should land in `bash` and arrow keys/history should work.

## Notes / assumptions
- OS: Debian/Ubuntu style package management (`apt-get`).
- Network egress must allow outbound HTTPS during boot.
- `/srv` mounting assumes you attach a second disk (common on Nitro: `/dev/nvme1n1`).

## Repo status
This repo intentionally keeps the bootstrap self-contained and defensive:
- waits for data disks
- avoids failing boot on optional tooling installs
- allows deterministic pinning (recommend pinning `GITHUB_REF` to a commit SHA)

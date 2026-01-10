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

### Launch Template / cloud-init example (recommended)
A common pattern is to use cloud-init `#cloud-config` user-data to download and run the bootstrap.

Example:
```yaml
#cloud-config
package_update: true
packages:
  - curl
  - ca-certificates

runcmd:
  - bash -lc 'mkdir -p /opt/agent-host'
  - bash -lc 'curl -fsSL https://raw.githubusercontent.com/joeyparis/agent-host-bootstrap/main/bootstrap.sh -o /opt/agent-host/bootstrap.sh'
  - bash -lc 'chmod +x /opt/agent-host/bootstrap.sh'
  - bash -lc '/opt/agent-host/bootstrap.sh'
```

Important:
- Each `runcmd` entry runs in its own process.
- If you want to pass environment variables (like `AGENT_HOST_CONFIG_NAME`), do it in the SAME command that runs the script.

### Setting the remote config name in cloud-init
To enable remote config for a specific deployment, set `AGENT_HOST_CONFIG_NAME` when you run the bootstrap:

```yaml
runcmd:
  - bash -lc 'AGENT_HOST_CONFIG_NAME=prod /opt/agent-host/bootstrap.sh'
```

If you also want strict behavior (fail boot if config fetch fails):
```yaml
runcmd:
  - bash -lc 'AGENT_HOST_CONFIG_NAME=prod REQUIRE_REMOTE_CONFIG=1 /opt/agent-host/bootstrap.sh'
```

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

### Remote config (persist Bitbucket SSH key + agentctl repos across instances)
By default, the bootstrap does NOT pull any shared configuration.

To enable shared config for a given deployment, set a deployment-specific config name:
- `AGENT_HOST_CONFIG_NAME=<name>`

This lets you run multiple independent deployments that:
- share the same config (use the same name), or
- use different configs (different names)

When `AGENT_HOST_CONFIG_NAME` is set, the bootstrap derives these default AWS resource names:
- Secrets Manager (Bitbucket SSH private key): `agent-host/<name>/bitbucket_ssh_private_key`
- SSM Parameter Store (agentctl `repos.txt`): `/agent-host/<name>/agentctl/repos_txt`

You can override either name directly:
- `BITBUCKET_SSH_KEY_SECRET_ID=...`
- `AGENTCTL_REPOS_SSM_PARAM_NAME=...`

Behavior:
- `REQUIRE_REMOTE_CONFIG` (default: `1` when remote config is enabled)
  - `1`: fail the bootstrap if the secret/parameter can’t be fetched
  - `0`: log a warning and continue
- `REMOTE_CONFIG_AWS_REGION` (optional): force the region used for AWS CLI calls

Post-launch syncing:
- You can apply (or switch) the remote config after the instance is already running:
  - `sudo -i -u agent agentctl sync-config joey-agents --region us-east-1`
- If the bootstrap applied remote config at boot time, it writes the last-used name to:
  - `/home/agent/.config/agentctl/remote_config_name`
  Then you can run `agentctl sync-config` with no args.

Important:
- This is an AWS account + region setup (Secrets Manager and SSM Parameter Store are region-scoped).
- Instances fetch these values via their instance profile (IAM role).

Required IAM permissions on the instance role:
- `secretsmanager:GetSecretValue` for the Bitbucket key secret
- `ssm:GetParameter` for the repos parameter
- plus `kms:Decrypt` if you use customer-managed KMS keys

Example setup (run from a workstation/CI with AWS creds):

Option A: use the helper script in this repo:
```bash
scripts/create_agent_host_remote_config.sh \
  --name my-config \
  --region us-east-1 \
  --ssh-key-file ./id_ed25519 \
  --repos-file ./repos.txt
```

Option B: run raw AWS CLI commands:
```bash
# Choose a config name (e.g. prod, staging, joey)
CFG=my-config
REGION=us-east-1

# 1) Create/update the Bitbucket SSH private key secret
# Store the private key file (e.g. id_ed25519) as secret-binary.
# If it already exists, use `aws secretsmanager update-secret` instead of `create-secret`.
aws --region "$REGION" secretsmanager create-secret \
  --name "agent-host/${CFG}/bitbucket_ssh_private_key" \
  --secret-binary fileb://id_ed25519

# 2) Create/update the agentctl repos list
aws --region "$REGION" ssm put-parameter \
  --name "/agent-host/${CFG}/agentctl/repos_txt" \
  --type String \
  --value "$(cat repos.txt)" \
  --overwrite
```

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

# Pull Bitbucket SSH key + repos.txt from AWS (optional remote config)
agentctl sync-config [config_name] [--region us-east-1]
```

Notes:
- `agentctl` is designed to run as the `agent` user.
- tmux windows created by `agentctl` run `bash -l` to ensure readline/history and arrow keys work reliably.
- Repos are cached under `/srv/git-mirrors/<repo>.git` as bare repos and checked out into per-agent worktrees.

Pushing changes:
- Commit in the worktree (e.g. `/srv/agents/<agent>/work/<repo>`), not inside `/srv/git-mirrors`.
- Safest push form:
  - `git push origin HEAD`

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

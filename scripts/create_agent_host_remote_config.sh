#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Create/update an agent-host remote config in AWS (per account + region).

This manages resources used by bootstrap.sh and agentctl sync-config.
All inputs are OPTIONAL: the script will only touch resources for flags you pass.

Clearing values:
- For Secrets Manager secrets, AWS requires SecretString/SecretBinary to be non-empty.
  So "clear" is implemented as deleting the secret (scheduled deletion).
  To clear a value, pass the corresponding flag with an empty string, e.g.:
    --bitbucket-mcp-credentials-file ""

Resources (derived from --name):
- Secrets Manager (Bitbucket SSH private key): agent-host/<name>/bitbucket_ssh_private_key
- SSM Parameter Store (agentctl repos.txt):    /agent-host/<name>/agentctl/repos_txt
- Secrets Manager (Bitbucket MCP credentials): agent-host/<name>/bitbucket_mcp_credentials

Usage:
  scripts/create_agent_host_remote_config.sh \
    --name <config_name> \
    --region <aws_region> \
    [--ssh-key-file /path/to/id_ed25519 | --ssh-key-file ""] \
    [--repos-file /path/to/repos.txt | --repos-file ""] \
    [--bitbucket-mcp-credentials-file /path/to/bitbucket.json | --bitbucket-mcp-credentials-file ""] \
    [--profile <aws_profile>] \
    [--kms-key-id <kms_key_id>] \
    [--param-type String|SecureString]

Examples:
  # Update only Bitbucket MCP creds (leave SSH key + repos untouched)
  scripts/create_agent_host_remote_config.sh \
    --name joey-agents \
    --region us-east-1 \
    --bitbucket-mcp-credentials-file ./bitbucket.json

Notes:
- Run this on your workstation/CI where AWS credentials are available.
- This is NOT run on the instance.
- No secrets are printed.
EOF
}

config_name=""
region=""
profile=""
ssh_key_file=""
repos_file=""
bitbucket_mcp_credentials_file=""
kms_key_id=""
param_type="String"

ssh_key_file_set=0
repos_file_set=0
bitbucket_mcp_credentials_file_set=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      config_name="$2"; shift 2 ;;
    --region)
      region="$2"; shift 2 ;;
    --profile)
      profile="$2"; shift 2 ;;
    --ssh-key-file)
      ssh_key_file_set=1
      ssh_key_file="$2"; shift 2 ;;
    --repos-file)
      repos_file_set=1
      repos_file="$2"; shift 2 ;;
    --bitbucket-mcp-credentials-file)
      bitbucket_mcp_credentials_file_set=1
      bitbucket_mcp_credentials_file="$2"; shift 2 ;;
    --kms-key-id)
      kms_key_id="$2"; shift 2 ;;
    --param-type)
      param_type="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$config_name" || -z "$region" ]]; then
  usage
  exit 2
fi

if [[ $ssh_key_file_set -eq 0 && $repos_file_set -eq 0 && $bitbucket_mcp_credentials_file_set -eq 0 ]]; then
  echo "ERROR: No actions requested. Pass at least one of: --ssh-key-file, --repos-file, --bitbucket-mcp-credentials-file" >&2
  usage
  exit 2
fi

if [[ "$param_type" != "String" && "$param_type" != "SecureString" ]]; then
  echo "ERROR: --param-type must be String or SecureString (got: $param_type)" >&2
  exit 2
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI not found." >&2
  exit 1
fi

secret_id="agent-host/${config_name}/bitbucket_ssh_private_key"
param_name="/agent-host/${config_name}/agentctl/repos_txt"
bitbucket_mcp_secret_id="agent-host/${config_name}/bitbucket_mcp_credentials"

aws_args=(--region "$region")
if [[ -n "$profile" ]]; then
  aws_args+=(--profile "$profile")
fi

schedule_delete_secret() {
  local sid="$1"
  echo "Deleting Secrets Manager secret (scheduled): $sid (region=$region)"
  # Safer default: scheduled deletion with the minimum recovery window (7 days).
  aws "${aws_args[@]}" secretsmanager delete-secret \
    --secret-id "$sid" \
    --recovery-window-in-days 7 \
    >/dev/null 2>&1 || true
}

# 1) Bitbucket SSH private key secret
if [[ $ssh_key_file_set -eq 1 ]]; then
  if [[ -z "${ssh_key_file}" ]]; then
    schedule_delete_secret "$secret_id"
  else
    if [[ ! -f "$ssh_key_file" ]]; then
      echo "ERROR: ssh key file not found: $ssh_key_file" >&2
      exit 1
    fi

    set +e
    aws "${aws_args[@]}" secretsmanager describe-secret --secret-id "$secret_id" >/dev/null 2>&1
    secret_exists=$?
    set -e

    if [[ $secret_exists -eq 0 ]]; then
      echo "Updating Secrets Manager secret: $secret_id (region=$region)"
      if [[ -n "$kms_key_id" ]]; then
        aws "${aws_args[@]}" secretsmanager update-secret \
          --secret-id "$secret_id" \
          --kms-key-id "$kms_key_id" \
          --secret-binary "fileb://$ssh_key_file" \
          >/dev/null
      else
        aws "${aws_args[@]}" secretsmanager update-secret \
          --secret-id "$secret_id" \
          --secret-binary "fileb://$ssh_key_file" \
          >/dev/null
      fi
    else
      echo "Creating Secrets Manager secret: $secret_id (region=$region)"
      create_args=(
        secretsmanager create-secret
        --name "$secret_id"
        --secret-binary "fileb://$ssh_key_file"
      )
      if [[ -n "$kms_key_id" ]]; then
        create_args+=(--kms-key-id "$kms_key_id")
      fi
      aws "${aws_args[@]}" "${create_args[@]}" >/dev/null
    fi
  fi
fi

# 2) agentctl repos list (SSM parameter)
if [[ $repos_file_set -eq 1 ]]; then
  if [[ -z "${repos_file}" ]]; then
    echo "Deleting SSM parameter: $param_name (region=$region)"
    aws "${aws_args[@]}" ssm delete-parameter --name "$param_name" >/dev/null 2>&1 || true
  else
    if [[ ! -f "$repos_file" ]]; then
      echo "ERROR: repos file not found: $repos_file" >&2
      exit 1
    fi

    echo "Putting SSM parameter: $param_name (type=$param_type region=$region)"
    aws "${aws_args[@]}" ssm put-parameter \
      --name "$param_name" \
      --type "$param_type" \
      --value "$(cat "$repos_file")" \
      --overwrite \
      >/dev/null
  fi
fi

# 3) Bitbucket MCP credentials secret (JSON secret string)
if [[ $bitbucket_mcp_credentials_file_set -eq 1 ]]; then
  if [[ -z "${bitbucket_mcp_credentials_file}" ]]; then
    schedule_delete_secret "$bitbucket_mcp_secret_id"
  else
    if [[ ! -f "$bitbucket_mcp_credentials_file" ]]; then
      echo "ERROR: Bitbucket MCP credentials file not found: $bitbucket_mcp_credentials_file" >&2
      exit 1
    fi

    echo "Creating/updating Bitbucket MCP credentials secret: $bitbucket_mcp_secret_id (region=$region)"

    set +e
    aws "${aws_args[@]}" secretsmanager describe-secret --secret-id "$bitbucket_mcp_secret_id" >/dev/null 2>&1
    mcp_secret_exists=$?
    set -e

    if [[ $mcp_secret_exists -eq 0 ]]; then
      if [[ -n "$kms_key_id" ]]; then
        aws "${aws_args[@]}" secretsmanager update-secret \
          --secret-id "$bitbucket_mcp_secret_id" \
          --kms-key-id "$kms_key_id" \
          --secret-string "$(cat "$bitbucket_mcp_credentials_file")" \
          >/dev/null
      else
        aws "${aws_args[@]}" secretsmanager update-secret \
          --secret-id "$bitbucket_mcp_secret_id" \
          --secret-string "$(cat "$bitbucket_mcp_credentials_file")" \
          >/dev/null
      fi
    else
      create_args=(
        secretsmanager create-secret
        --name "$bitbucket_mcp_secret_id"
        --secret-string "$(cat "$bitbucket_mcp_credentials_file")"
      )
      if [[ -n "$kms_key_id" ]]; then
        create_args+=(--kms-key-id "$kms_key_id")
      fi
      aws "${aws_args[@]}" "${create_args[@]}" >/dev/null
    fi
  fi
fi

echo "Done. Bootstrap/agentctl can now use: AGENT_HOST_CONFIG_NAME=$config_name"

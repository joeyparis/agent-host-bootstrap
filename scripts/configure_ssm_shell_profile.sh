#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/configure_ssm_shell_profile.sh [--region REGION] [--profile PROFILE] [--shell "exec /bin/bash -l"]

What this does:
  Session Manager defaults to starting /bin/sh on Linux, which doesn't support readline arrow-key history.
  This script updates the Session Manager preferences document (SSM-SessionManagerRunShell) to exec bash.

Notes:
  - This is an AWS account + region setting (not per-instance).
  - Requires AWS CLI credentials with permissions to read/update the document.
  - Requires jq.
EOF
}

region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
profile=""
shell_cmd="exec /bin/bash -l"
doc_name="SSM-SessionManagerRunShell"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      region="$2"
      shift 2
      ;;
    --profile)
      profile="$2"
      shift 2
      ;;
    --shell)
      shell_cmd="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${region:-}" ]]; then
  echo "ERROR: region not set. Provide --region or set AWS_REGION/AWS_DEFAULT_REGION." >&2
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI not found." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not found." >&2
  exit 1
fi

aws_args=(--region "$region")
if [[ -n "$profile" ]]; then
  aws_args+=(--profile "$profile")
fi

set +e
content_raw="$(aws "${aws_args[@]}" ssm get-document --name "$doc_name" --document-version '$LATEST' --query Content --output text 2>/dev/null)"
status=$?
set -e

if [[ $status -ne 0 || -z "${content_raw:-}" || "${content_raw:-}" == "None" ]]; then
  cat >&2 <<EOF
ERROR: Could not read $doc_name in region $region.

This document is created when you configure Session Manager preferences in that region.
Open: Systems Manager -> Session Manager -> Preferences, save once, then re-run this script.
EOF
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

in_file="$tmp_dir/in.json"
out_file="$tmp_dir/out.json"

echo "$content_raw" >"$in_file"

jq --arg linux_shell "$shell_cmd" '
  .inputs.shellProfile = (.inputs.shellProfile // {})
  | .inputs.shellProfile.linux = $linux_shell
' "$in_file" >"$out_file"

update_out="$tmp_dir/update.json"
aws "${aws_args[@]}" ssm update-document \
  --name "$doc_name" \
  --document-version '$LATEST' \
  --document-format JSON \
  --content "file://$out_file" \
  >"$update_out"

latest_version="$(jq -r '.DocumentDescription.LatestVersion // empty' "$update_out")"
if [[ -z "${latest_version:-}" ]]; then
  echo "ERROR: Could not determine LatestVersion from update-document output." >&2
  cat "$update_out" >&2
  exit 1
fi

aws "${aws_args[@]}" ssm update-document-default-version \
  --name "$doc_name" \
  --document-version "$latest_version" \
  >/dev/null

echo "Updated $doc_name in region=$region to start: $shell_cmd"
echo "Set default version to: $latest_version"

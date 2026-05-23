#!/usr/bin/env bash
# shell/agents/hermes/apply-model-config.sh
#
# Op contract (per op-dispatch-protocol/spec.md D5):
#   stdin            : API key (raw string, no trailing newline required)
#   env vars read    : INSTALLER_OP_PROVIDER    (required) — e.g. "openai"
#                      INSTALLER_OP_MODEL       (required) — e.g. "gpt-4o"
#                      INSTALLER_OP_BASE_URL    (required) — e.g. "https://api.openai.com/v1"
#                      INSTALLER_OP_ENV_VAR_NAME (required) — e.g. "OPENAI_API_KEY"
#   stdout           : empty on success
#   exit 0           : all hermes config set + .env upsert steps succeeded
#   exit non-zero    : any step failed

set -euo pipefail

__SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$__SELF_DIR/../../lib/common.sh"

# Compose PATH so hermes binary is available.
_claw_compose_path

# ---------------------------------------------------------------------------
# Validate required env vars.
# ---------------------------------------------------------------------------
: "${INSTALLER_OP_PROVIDER:?INSTALLER_OP_PROVIDER is required}"
: "${INSTALLER_OP_MODEL:?INSTALLER_OP_MODEL is required}"
: "${INSTALLER_OP_BASE_URL:?INSTALLER_OP_BASE_URL is required}"
: "${INSTALLER_OP_ENV_VAR_NAME:?INSTALLER_OP_ENV_VAR_NAME is required}"

# ---------------------------------------------------------------------------
# Apply hermes model config.
# ---------------------------------------------------------------------------
hermes config set model.provider "$INSTALLER_OP_PROVIDER"
hermes config set model.default  "$INSTALLER_OP_MODEL"
hermes config set model.base_url "$INSTALLER_OP_BASE_URL"

# ---------------------------------------------------------------------------
# Read API key from stdin, upsert into ~/.hermes/.env with mode 0600.
# ---------------------------------------------------------------------------
_api_key="$(cat)"

_env_dir="$HOME/.hermes"
mkdir -p "$_env_dir"
_env_file="$_env_dir/.env"

_env_key="$INSTALLER_OP_ENV_VAR_NAME"
_tmp="${_env_file}.tmp.$$"
trap 'rm -f "$_tmp"' EXIT

if [ -f "$_env_file" ]; then
  grep -v "^${_env_key}=" "$_env_file" > "$_tmp" || :
else
  : > "$_tmp"
fi
printf '%s=%s\n' "$_env_key" "$_api_key" >> "$_tmp"
mv "$_tmp" "$_env_file"
chmod 600 "$_env_file"

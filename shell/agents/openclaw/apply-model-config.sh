#!/usr/bin/env bash
# shell/agents/openclaw/apply-model-config.sh
#
# Op contract (per op-dispatch-protocol/spec.md D5):
#   stdin            : JSON patch payload (required — must be valid JSON)
#   env vars read    : INSTALLER_OP_REPLACE_PATHS (optional)
#                        Space-separated list of --replace-path arguments to
#                        pass to `openclaw config patch`. Default: empty (no
#                        --replace-path flags added).
#   stdout           : empty on success (all output goes to stderr)
#   exit 0           : both `openclaw config patch` and `openclaw config validate`
#                      succeeded and the temp file was cleaned up
#   exit non-zero    : either command failed; temp file is still removed via
#                      the EXIT trap before this script exits

set -euo pipefail

__SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$__SELF_DIR/../../lib/common.sh"

# Compose PATH so fnm-managed Node (required by openclaw via pnpm) is available.
_claw_compose_path

# ---------------------------------------------------------------------------
# Read stdin into a chmod-600 temp file. EXIT trap guarantees cleanup.
# ---------------------------------------------------------------------------
_nanos="$(date +%s%N 2>/dev/null || date +%s)"
_patch_tmp="$(_claw_tmp_dir)/openclaw-patch-$$-${_nanos}.json"
trap 'rm -f "$_patch_tmp"' EXIT

cat > "$_patch_tmp"
chmod 600 "$_patch_tmp"

# ---------------------------------------------------------------------------
# Build the openclaw config patch command with optional --replace-path flags.
# ---------------------------------------------------------------------------
_patch_cmd=(openclaw config patch --file "$_patch_tmp")

if [[ -n "${INSTALLER_OP_REPLACE_PATHS:-}" ]]; then
  for _rp in $INSTALLER_OP_REPLACE_PATHS; do
    _patch_cmd+=(--replace-path "$_rp")
  done
fi

# ---------------------------------------------------------------------------
# Apply patch then validate.
# ---------------------------------------------------------------------------
"${_patch_cmd[@]}"
openclaw config validate

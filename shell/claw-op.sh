#!/usr/bin/env bash
# shell/claw-op.sh — macOS/Linux op dispatcher for the unified op-dispatch protocol.
#
# Usage:
#   bash shell/claw-op.sh --op <op-name> --agent <agent-name>
#
# Stdin: forwarded unchanged to the op script.
# Env:   INSTALLER_OP_* variables are forwarded to the op script as-is.
# Exit:  exits with the op script's exit code; exits non-zero before any exec
#        if op or agent is unrecognized.
#
# This script is the macOS/Linux counterpart of bootstrap.ps1's Invoke-OpDispatch.
# Rust invokes it via: bash /path/to/shell/claw-op.sh --op <op> --agent <agent>
# with login_env applied and stdin_bytes piped to the process stdin.
#
# Bash 3.x compatible (macOS ships with bash 3.2): no declare -A, no [[ -v ]].

set -euo pipefail

# ---------------------------------------------------------------------------
# Dispatch table lookup: returns valid agents for an op (space-separated), or
# empty string if op is unknown. Using a case statement for bash 3 compat.
# Must mirror $script:OpAgentTable in shell/windows/bootstrap.ps1.
# ---------------------------------------------------------------------------
_op_valid_agents() {
  local op="$1"
  case "$op" in
    apply-model-config)    echo 'openclaw hermes' ;;
    open-dashboard)        echo 'openclaw hermes' ;;
    approve-latest-device) echo 'openclaw' ;;
    find-dashboard-port)   echo 'hermes' ;;
    pair-bubbolink)        echo 'openclaw hermes' ;;
    *)                     echo '' ;;
  esac
}

_all_ops() {
  echo 'apply-model-config open-dashboard approve-latest-device find-dashboard-port pair-bubbolink'
}

_usage() {
  echo "Usage: $(basename "$0") --op <op-name> --agent <agent-name>" >&2
  echo "" >&2
  echo "Valid ops: $(_all_ops)" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Parse --op / --agent from argv.
# ---------------------------------------------------------------------------
_op=''
_agent=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --op)
      [[ $# -ge 2 ]] || _usage
      _op="$2"
      shift 2
      ;;
    --agent)
      [[ $# -ge 2 ]] || _usage
      _agent="$2"
      shift 2
      ;;
    *)
      echo "$(basename "$0"): unknown argument: $1" >&2
      _usage
      ;;
  esac
done

if [[ -z "$_op" || -z "$_agent" ]]; then
  echo "$(basename "$0"): --op and --agent are both required." >&2
  _usage
fi

# ---------------------------------------------------------------------------
# Validate op name.
# ---------------------------------------------------------------------------
_valid_agents_for_op="$(_op_valid_agents "$_op")"
if [[ -z "$_valid_agents_for_op" ]]; then
  echo "$(basename "$0"): unknown op '$_op'." >&2
  echo "Valid ops: $(_all_ops)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Validate agent for this op.
# ---------------------------------------------------------------------------
_agent_ok=0
for _a in $_valid_agents_for_op; do
  if [[ "$_a" == "$_agent" ]]; then
    _agent_ok=1
    break
  fi
done
if [[ $_agent_ok -eq 0 ]]; then
  echo "$(basename "$0"): op '$_op' does not support agent '$_agent'." >&2
  echo "Valid agents for '$_op': $_valid_agents_for_op" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Derive the shell/ root (this script lives directly inside shell/).
# ---------------------------------------------------------------------------
__SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_op_script="$__SELF_DIR/agents/$_agent/$_op.sh"
if [[ ! -f "$_op_script" ]]; then
  echo "$(basename "$0"): op script not found: $_op_script" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Exec the op script with stdin inherited from the caller.
# ---------------------------------------------------------------------------
exec bash "$_op_script"

#!/usr/bin/env bash
# shell/agents/hermes/find-dashboard-port.sh
#
# Op contract (per op-dispatch-protocol/spec.md D5):
#   stdin            : none (redirected from /dev/null by dispatch layer)
#   env vars read    : none
#   stdout           : port number (integer only, no decoration) when a running
#                      `hermes dashboard` process with --port N is found;
#                      empty when no such process exists
#   exit 0           : always (whether port found or not)
#
# Mirrors the logic in dashboard.rs::parse_hermes_port: scan ps output for any
# line containing both "hermes" and "dashboard", then extract the value after
# "--port". Processes with no --port flag produce no output (caller uses the
# documented default port 9119).

set -euo pipefail

__SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$__SELF_DIR/../../lib/common.sh"

# No _claw_compose_path needed — we only call ps, grep, awk here.

ps -eo args= 2>/dev/null \
  | grep 'hermes' \
  | grep 'dashboard' \
  | grep -o '\-\-port [0-9]*' \
  | awk '{print $2; exit}' \
  || true

#!/usr/bin/env bash
# shell/agents/hermes/open-dashboard.sh
#
# Op contract (per op-dispatch-protocol/spec.md D5):
#   stdin            : none (redirected from /dev/null by dispatch layer)
#   env vars read    : none
#   stdout           : preflight diagnostics + sentinel "@@hermes-spawn-log:<path>"
#                      pointing to the file where hermes's own output lives
#                      (inside WSL, e.g. /tmp/claw-installer/hermes-dashboard-spawn-*.log)
#   exit 0           : daemon spawned, still alive at +2s (best-effort)
#   exit 1           : preflight failed (binary missing / unrunnable) OR
#                      hermes process exited within 2s of spawn (early crash)
#
# Why the spawn log: previously this script did `nohup hermes dashboard ... >/dev/null 2>&1 &`
# which discarded ALL of hermes's output. If hermes failed (missing fastapi /
# uvicorn in its venv, web UI build error, port in use, etc.), the process
# died silently and the caller spent 60s polling a never-listening port with
# no idea why. Tee'ing the spawn's output to a known file lets us (or the
# user) inspect post-mortem with `wsl -- cat <path>`.
#
# --no-open: suppress hermes's built-in browser launch — the Rust caller
# opens the URL itself once it confirms the TCP port is listening.

set -euo pipefail

__SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$__SELF_DIR/../../lib/common.sh"

# Compose PATH so the hermes binary (~/.local/bin/hermes installed by
# upstream's installer) is available.
_claw_compose_path

# Preflight 1: hermes binary on PATH at all?
if ! command -v hermes >/dev/null 2>&1; then
  echo "[hermes/open-dashboard] hermes binary not found on PATH" >&2
  echo "[hermes/open-dashboard] PATH=$PATH" >&2
  echo "[hermes/open-dashboard] try running the installer again, or run \`source ~/.bashrc\` in a fresh terminal" >&2
  exit 1
fi
echo "[hermes/open-dashboard] hermes binary: $(command -v hermes)"

# Preflight 2: hermes binary runnable (catches broken venv / missing python).
# Use a subshell + capture so we can surface errors verbatim.
if _ver="$(hermes --version 2>&1)"; then
  echo "[hermes/open-dashboard] hermes --version: $_ver"
else
  echo "[hermes/open-dashboard] hermes --version failed:" >&2
  printf '%s\n' "$_ver" >&2
  exit 1
fi

# Set up a known log path so post-mortem inspection is straightforward.
_log_dir="/tmp/claw-installer"
mkdir -p "$_log_dir"
_spawn_log="$_log_dir/hermes-dashboard-spawn-$(date +%s).log"

echo "[hermes/open-dashboard] spawning: hermes dashboard --no-open"
echo "[hermes/open-dashboard] spawn log: $_spawn_log"

# Fire-and-forget: tee output to the spawn log instead of /dev/null. setsid
# detaches from our process group so killing our bash (after exit 0) won't
# cascade SIGHUP to hermes. `disown` keeps bash from waiting on the pid.
setsid nohup hermes dashboard --no-open >"$_spawn_log" 2>&1 </dev/null &
_spawn_pid=$!
disown
echo "[hermes/open-dashboard] spawned pid=$_spawn_pid"

# Best-effort early-failure check: give hermes 2 seconds to crash. If it
# already exited, surface the spawn log content so the operator sees the
# error without having to poll for 60s on a dead process.
sleep 2
if ! kill -0 "$_spawn_pid" 2>/dev/null; then
  echo "[hermes/open-dashboard] hermes exited within 2s — likely startup failure" >&2
  echo "[hermes/open-dashboard] last 50 lines from $_spawn_log:" >&2
  tail -n 50 "$_spawn_log" >&2 || true
  exit 1
fi
echo "[hermes/open-dashboard] hermes still alive at +2s; backgrounded successfully"

# Sentinel for the Rust caller, in case it wants to surface the log path in
# its own diagnostics. (Not required for the polling flow.)
printf '@@hermes-spawn-log:%s\n' "$_spawn_log"

exit 0

#!/usr/bin/env bash
# shell/agents/openclaw/approve-latest-device.sh
#
# Op contract (per op-dispatch-protocol/spec.md D5):
#   stdin            : none (redirected from /dev/null by dispatch layer)
#   env vars read    : none
#   stdout           : "approved (count=N)" on success (one line at end)
#   exit 0           : at least one pending request was approved AND no more
#                      pending requests appeared during the post-approve
#                      drain window (or we hit the iteration cap after
#                      approving ≥ 1).
#   exit 1           : no pending request ever appeared within ~30s.
#
# Design: the polling loop lives HERE (not in Rust) so that a single
# dispatch_op call (one UAC prompt max on Windows) handles the full
# approval wait. Drain mode: openclaw can produce multiple concurrent
# pending requests (new-pairing for the browser, scope-upgrade for the
# CLI, etc.) — we approve them all rather than just the first one, since
# the browser side stays blocked until every dependency is approved.
#
# openclaw enforces a deliberate TWO-STEP approval ceremony to prevent
# race conditions (see openclaw/src/cli/devices-cli.runtime.ts:681 —
# "Keep implicit selection preview-only. A second command with the exact
# requestId binds the approval to the request the operator inspected."):
#
#   step 1: `openclaw devices approve --latest --json`
#           preview-only; prints JSON containing `selected.requestId` and
#           ALWAYS exits 1 (this is by design, not an error). Returns
#           "No pending device pairing requests to approve" on stderr
#           when nothing is pending.
#
#   step 2: `openclaw devices approve <requestId>`
#           actually approves. No interactive prompt, no --yes flag —
#           openclaw approves the explicit id directly. Local-CLI path
#           through `approvePairingWithFallback` auto-grants
#           `operator.admin` scope (see devices-cli.runtime.ts:253-257)
#           because same-machine access is already a sufficient capability,
#           so we never need --token/--password here.
#
# We poll step 1 until a requestId appears, then run step 2 once. Earlier
# attempts using `--yes` (openclaw rejects: "does not recognize option")
# or `printf 'y\n' | …` (no prompt exists; openclaw doesn't read stdin
# for confirmation) were dead ends — confirmed by reading openclaw source.

set -uo pipefail

__SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$__SELF_DIR/../../lib/common.sh"

# Compose PATH so fnm-managed Node (required by openclaw via pnpm) is available.
_claw_compose_path

# Caller-overridable knobs. The two operating modes:
#
#   1. Open-dashboard mode (default):
#      Wait up to ~30s for a pending request to appear (browser is loading
#      and will create one). Exit 1 if nothing ever shows up.
#
#   2. Install-time warmup mode (INSTALLER_APPROVE_NEVER_FOUND_OK=1):
#      Quickly drain any requests already queued by the install's own
#      `openclaw doctor` / `gateway start` calls (CLI scope-upgrade etc.),
#      then exit 0 cleanly when the queue is empty — even if we approved
#      nothing. Uses a shorter budget (typically 10 iters / 4s) since
#      anything we expect to find is already there.
_max_iterations="${INSTALLER_APPROVE_MAX_ITERATIONS:-75}"
_sleep_secs=0.4
_never_found_ok="${INSTALLER_APPROVE_NEVER_FOUND_OK:-0}"

# Extract `selected.requestId` from `openclaw devices approve --latest --json`
# stdout. Uses node (already on PATH via _claw_compose_path) so we don't
# depend on jq being installed in the user's WSL distro. Echoes the id on
# stdout, or nothing if the input isn't valid JSON / has no pending request.
_extract_request_id() {
  node -e '
    let data = "";
    process.stdin.on("data", c => data += c);
    process.stdin.on("end", () => {
      try {
        const obj = JSON.parse(data);
        if (obj && obj.selected && typeof obj.selected.requestId === "string") {
          process.stdout.write(obj.selected.requestId);
        }
      } catch (_) {}
    });
  ' 2>/dev/null
}

# DRAIN, not one-shot: openclaw can have multiple concurrent pending
# requests of different kinds — `new-pairing` for the browser's device,
# `scope-upgrade` / `role-upgrade` / `re-approval` for the CLI session's
# own identity (especially on a fresh install where the CLI itself needs
# elevated scopes to do RPC calls to the gateway). Browser-side dashboard
# stays blocked until ALL the requests it depends on are approved.
#
# We saw this empirically on a fresh-install run: the browser-pairing
# request was approved successfully, but a `scope-upgrade` request stayed
# pending — leaving the browser stuck on "needs device approve" forever.
# The fix is to keep approving until `--latest --json` reports nothing.
#
# Termination policy:
#   - Approved >= 1 AND _no_pending_streak >= POST_APPROVE_DRAIN_ITER:
#     we've successfully approved at least once and haven't seen new
#     requests for ~POST_APPROVE_DRAIN_ITER × _sleep_secs seconds. Exit 0.
#   - Approved == 0 AND iter >= _max_iterations: timed out waiting for the
#     first pending request to appear. Exit 1 with diagnostic.
echo "[approve-latest-device] polling openclaw for pending device-pairing requests (max=${_max_iterations} iterations × ${_sleep_secs}s, drain mode)"

_approved_count=0
_no_pending_streak=0
POST_APPROVE_DRAIN_ITER=10  # ~4s of no-new-requests after last approval

for _i in $(seq 1 "$_max_iterations"); do
  # Step 1: query latest pending. `--latest --json` always exits 1, so
  # capture stdout via $() and ignore exit code via `|| true`.
  preview_json="$(openclaw devices approve --latest --json 2>/dev/null || true)"
  request_id=""
  if [[ -n "$preview_json" ]]; then
    request_id="$(printf '%s' "$preview_json" | _extract_request_id || true)"
  fi

  if [[ -n "$request_id" ]]; then
    _no_pending_streak=0
    echo "[approve-latest-device] found pending requestId=${request_id}; running explicit approve (already approved=${_approved_count})"
    # Step 2: actual approval. No --latest, no --json — explicit id binds
    # the approval to the request we just inspected (anti-race).
    if approve_output="$(openclaw devices approve "$request_id" 2>&1)"; then
      printf '%s\n' "$approve_output"
      _approved_count=$((_approved_count + 1))
      echo "[approve-latest-device] approved (total=${_approved_count}); checking for more pending requests immediately"
      # NO sleep here — drain mode: immediately re-query for the next
      # pending request (a scope-upgrade might already be queued behind
      # the one we just cleared).
      continue
    fi
    # Approve failed — surface the error so the next loop iteration (or
    # the operator) can see what openclaw is complaining about. Could be
    # a transient gateway issue, a token-changed-between-steps race, etc.
    echo "[approve-latest-device] explicit approve failed for ${request_id}:" >&2
    printf '%s\n' "$approve_output" >&2
    # Fall through to sleep + retry.
  else
    _no_pending_streak=$((_no_pending_streak + 1))
    # Exit condition: we've approved at least once AND haven't seen new
    # pending requests for POST_APPROVE_DRAIN_ITER consecutive iterations.
    # This is the success path for the multi-request scenario — we drained
    # everything we know about.
    if (( _approved_count > 0 && _no_pending_streak >= POST_APPROVE_DRAIN_ITER )); then
      echo "approved (count=${_approved_count})"
      exit 0
    fi
  fi

  # Heartbeat every 10 iterations (~4s) so the op log shows the loop is
  # alive even when polling is silent (no pending request yet).
  if (( _i % 10 == 0 )); then
    echo "[approve-latest-device] still polling, iter=${_i} approved=${_approved_count} no_pending_streak=${_no_pending_streak}"
  fi
  sleep "$_sleep_secs"
done

# Hit the iteration cap. If we approved at least once, treat as success
# (we drained what we could within the budget) — better than failing the
# whole op when the actual browser pairing has been approved.
if (( _approved_count > 0 )); then
  echo "approved (count=${_approved_count}, iteration-cap reached but at least one request approved)"
  exit 0
fi

# Final diagnostic pass: stderr-visible so the op log captures whatever
# openclaw is actually saying (e.g. "No pending device pairing requests").
echo "[approve-latest-device] iteration cap reached (${_max_iterations}); final diagnostic:" >&2
openclaw devices approve --latest --json >&2 || true

# Warmup mode treats "nothing pending" as success. Open-dashboard mode
# treats it as failure because the browser is presumed to be loading and
# should have produced a request within the budget.
if [[ "$_never_found_ok" == "1" ]]; then
  echo "[approve-latest-device] warmup mode: no pending requests during budget — exiting clean"
  exit 0
fi

echo "timeout: no pending device pairing request approved" >&2
exit 1

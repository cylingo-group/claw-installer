#!/usr/bin/env bash
# shell/agents/openclaw/open-dashboard.sh
#
# Op contract (per op-dispatch-protocol/spec.md D5):
#   stdin            : none (redirected from /dev/null by dispatch layer)
#   env vars read    : none
#   stdout           : openclaw's own stdout/stderr, plus a sentinel line
#                      `@@dashboard-url:<url>` carrying the gateway URL for
#                      Rust to open via the Tauri opener plugin.
#   exit code        : exit code of `openclaw dashboard --no-open --yes`
#
# Why `--no-open`:
#   On macOS native, openclaw detects a GUI and launches the system browser
#   itself (via openUrl → open(1)). Our Rust caller ALSO opens the URL via
#   the Tauri opener. Without --no-open the user gets two tabs — one with
#   token (openclaw's), one without (ours, from the bare URL on stdout).
#   With --no-open openclaw skips its own launch and still writes the
#   token-bearing URL to the system clipboard, which we read back below.
#   On WSL it's a no-op because openclaw already refused to open a browser
#   (its "No GUI" branch).
#
# --yes auto-installs the gateway service if missing, so a freshly
# installed openclaw that hasn't been started can still surface its dashboard.

set -uo pipefail

__SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$__SELF_DIR/../../lib/common.sh"

# Compose PATH so fnm-managed Node (required by openclaw via pnpm) is available.
_claw_compose_path

# Read the system clipboard with whichever tool fits the current OS. Output
# goes to stdout on success; empty (and a non-zero return is fine) on miss.
# We mirror openclaw's own clipboard-writing fallback chain (see
# openclaw/src/infra/clipboard.ts): pbcopy → xclip → wl-copy → clip.exe →
# powershell Set-Clipboard. The READ-side equivalents are pbpaste / xclip -o
# / wl-paste / powershell Get-Clipboard. We try them in the same priority
# order so we read from whichever target openclaw wrote to.
_read_clipboard() {
  if command -v pbpaste >/dev/null 2>&1; then
    pbpaste 2>/dev/null
    return
  fi
  if command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard -o 2>/dev/null
    return
  fi
  if command -v wl-paste >/dev/null 2>&1; then
    wl-paste 2>/dev/null
    return
  fi
  # WSL → Windows clipboard. powershell.exe lives at a fixed path under
  # /mnt/c on every WSL2 host where the Windows side has PowerShell 5.1+
  # (i.e. every Win 10/11).
  local ps_exe="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
  if [[ -x "$ps_exe" ]]; then
    "$ps_exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
      -Command Get-Clipboard 2>/dev/null
    return
  fi
}

# Capture openclaw's output so we can both pass it through (for the user-
# visible log) and parse the URL out.
output="$(openclaw dashboard --no-open --yes 2>&1)"
rc=$?

# Pass openclaw's full output through so it appears in the op log file.
printf '%s\n' "$output"

# Parse the bare URL (no token) from openclaw's `Dashboard URL: …` line.
bare_url="$(printf '%s\n' "$output" \
  | grep -E '^Dashboard URL: *http://' \
  | head -n 1 \
  | sed -E 's/^Dashboard URL: *//' \
  | tr -d '[:space:]')"

# openclaw prints `Token auto-auth included in browser/clipboard URL.` /
# `Copied to clipboard.` — the BARE URL on stdout has no token, but the
# token-bearing URL went to the system clipboard via openclaw's
# copyToClipboard. Read it back so we can hand the browser a URL that
# authenticates itself.
#
# Accept the clipboard content ONLY if it looks like a richer version of
# $bare_url (same host:port prefix, longer, has a query or fragment) —
# otherwise the user's pre-existing clipboard could leak in and we'd open
# the wrong URL.
token_url=""
if [[ -n "$bare_url" ]]; then
  # Strip trailing slash so the prefix-match handles both
  # `http://127.0.0.1:7841` and `http://127.0.0.1:7841/`.
  bare_prefix="${bare_url%/}"
  clip_first_line="$(_read_clipboard \
    | tr -d '\r' \
    | grep -m1 -E '^http://[^[:space:]]+' || true)"
  if [[ -n "$clip_first_line" \
        && "$clip_first_line" == "$bare_prefix"* \
        && ${#clip_first_line} -gt ${#bare_url} \
        && ( "$clip_first_line" == *"?"* || "$clip_first_line" == *"#"* ) ]]; then
    token_url="$clip_first_line"
    printf '[open-dashboard] using token-bearing URL from system clipboard\n'
  else
    printf '[open-dashboard] clipboard did not contain a richer URL (got: %q); falling back to bare URL — dashboard may require manual auth\n' "$clip_first_line"
  fi
fi

# Prefer the clipboard URL (carries the token); fall back to bare URL.
dashboard_url="${token_url:-$bare_url}"

if [[ -n "$dashboard_url" ]]; then
  printf '@@dashboard-url:%s\n' "$dashboard_url"
fi

exit "$rc"

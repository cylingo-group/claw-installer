#!/usr/bin/env bash
# verify-fnm-fix.sh — Apply the proposed fix IN-MEMORY (without touching the
# user's installed common.sh) and verify it actually puts node on PATH.
#
# Strategy:
#   1. Source the user's prod ~/claw-installer-src/lib/common.sh (broken state)
#   2. Redefine _claw_fnm_active_bin with the fix (use $d/aliases/default/bin
#      directly — works for both relative and absolute symlink targets)
#   3. Also `eval $(fnm env)` as the canonical Layer-1 mechanism
#   4. Re-run _claw_compose_path with the fixed function
#   5. Report: command -v node / openclaw / pnpm, then try `openclaw --version`
#
# If openclaw --version succeeds (no "exec: node: not found"), the fix works.

set -uo pipefail

echo "════════════════════════════════════════════════════════════════"
echo " verify-fnm-fix.sh — in-memory fix verification"
echo "════════════════════════════════════════════════════════════════"

COMMON="$HOME/claw-installer-src/lib/common.sh"
if [ ! -f "$COMMON" ]; then
    echo "[verify-fix] FATAL: common.sh missing at $COMMON"
    exit 2
fi

echo "── step 1: source prod common.sh (broken state) ──"
# shellcheck disable=SC1090
source "$COMMON"
echo "command -v node after prod source: $(command -v node 2>/dev/null || echo '(not found)')"
echo

echo "── step 2: apply Layer 2 fix (redefine _claw_fnm_active_bin) ──"
_claw_fnm_active_bin() {
    local d candidates=(
        "$HOME/.local/share/fnm"
        "$HOME/.fnm"
        "$HOME/Library/Application Support/fnm"
        "${XDG_DATA_HOME:-}/fnm"
    )
    for d in "${candidates[@]}"; do
        [[ -z "$d" || "$d" == "/fnm" ]] && continue
        # aliases/default IS a symlink to the installation dir; use it directly
        # so we don't have to parse the symlink target (which may be absolute
        # or relative depending on fnm version).
        if [[ -d "$d/aliases/default/bin" ]]; then
            printf '%s' "$d/aliases/default/bin"
            return 0
        fi
    done
    return 1
}

# Re-run compose with the redefined function
_claw_compose_path
echo "command -v node after Layer 2 fix: $(command -v node 2>/dev/null || echo '(not found)')"
echo

echo "── step 3: apply Layer 1 fix (eval \$(fnm env)) ──"
if command -v fnm >/dev/null 2>&1; then
    fnm_output="$(fnm env --shell bash 2>/dev/null)"
    if [ -n "$fnm_output" ]; then
        eval "$fnm_output"
        echo "[verify-fix] fnm env eval'd ($(printf '%s' "$fnm_output" | wc -c) bytes)"
    else
        echo "[verify-fix] fnm env returned empty"
    fi
else
    echo "[verify-fix] fnm not on PATH (Layer 2 should have added it via resolve_fnm_dir)"
fi
echo "command -v node after Layer 1 fix: $(command -v node 2>/dev/null || echo '(not found)')"
echo

# Clear bash command hash so subsequent lookups are honest.
hash -r 2>/dev/null || true

echo "── final state ──"
echo "PATH (first 8 entries):"
echo "$PATH" | tr ':' '\n' | head -8 | sed 's/^/    /'
echo
echo "command -v:"
for c in node openclaw pnpm fnm hermes; do
    p="$(command -v "$c" 2>/dev/null || echo '(not found)')"
    printf '  %-10s %s\n' "$c" "$p"
done
echo

# Real test: does `openclaw --version` work now?
if ! command -v node >/dev/null 2>&1; then
    echo "[verify-fix] FAIL: node still not on PATH after both layers"
    exit 3
fi
if ! command -v openclaw >/dev/null 2>&1; then
    echo "[verify-fix] FAIL: openclaw not on PATH (pnpm install issue?)"
    exit 4
fi

echo "── versions (the real test) ──"
echo "node:"
node --version 2>&1 | sed 's/^/    /'
node_rc=${PIPESTATUS[0]}
echo "openclaw:"
openclaw --version 2>&1 | sed 's/^/    /'
oc_rc=${PIPESTATUS[0]}

echo
if [ "$node_rc" -eq 0 ] && [ "$oc_rc" -eq 0 ]; then
    echo "[verify-fix] PASS — both node and openclaw run cleanly"
    echo "[verify-fix]        → applying the same fix to prod common.sh will resolve the bug"
    exit 0
else
    echo "[verify-fix] FAIL — node_rc=$node_rc openclaw_rc=$oc_rc"
    exit 5
fi

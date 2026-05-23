#!/usr/bin/env bash
# noop.sh — Diagnostic op. Sources common.sh (if present), prints the
# resulting PATH + canonical command resolutions + INSTALLER_OP_* env vars,
# then exits 0.
#
# Used by probe scenarios G, N (the architectural-fix verification).

set -uo pipefail

echo "════════════════════════════════════════════════════════════════"
echo " noop.sh — diagnostic op"
echo "════════════════════════════════════════════════════════════════"

echo "[noop] uname:           $(uname -a)"
echo "[noop] whoami:          $(whoami)"
echo "[noop] HOME:            $HOME"
echo "[noop] PWD:             $(pwd)"
echo "[noop] shell:           $0  ($BASH_VERSION)"
echo "[noop] is-interactive:  $([[ $- == *i* ]] && echo yes || echo no)"
echo "[noop] is-login:        $(shopt -q login_shell && echo yes || echo no)"
echo

echo "── PATH BEFORE sourcing common.sh ──"
echo "PATH=$PATH"
echo
echo "── command -v BEFORE source ──"
for c in node openclaw pnpm fnm hermes; do
    p=$(command -v "$c" 2>/dev/null || echo "(not found)")
    printf "  %-10s %s\n" "$c" "$p"
done
echo

# Try to locate + source common.sh.
COMMON_CANDIDATES=(
    "$HOME/claw-installer-src/lib/common.sh"
    "/mnt/c/Users/$(whoami)/claw-installer-src/lib/common.sh"
)
COMMON=""
for c in "${COMMON_CANDIDATES[@]}"; do
    if [ -f "$c" ]; then
        COMMON="$c"
        break
    fi
done

if [ -z "$COMMON" ]; then
    echo "── common.sh NOT FOUND (tried: ${COMMON_CANDIDATES[*]}) ──"
    echo "[noop] skipping source step"
else
    echo "── sourcing $COMMON ──"
    # shellcheck disable=SC1090
    source "$COMMON"
    echo "[noop] source returned $?"
    echo
    echo "── PATH AFTER sourcing common.sh ──"
    echo "PATH=$PATH"
    echo
    echo "── command -v AFTER source ──"
    for c in node openclaw pnpm fnm hermes; do
        p=$(command -v "$c" 2>/dev/null || echo "(not found)")
        printf "  %-10s %s\n" "$c" "$p"
    done
    echo
    echo "── versions ──"
    if command -v node >/dev/null 2>&1; then
        echo "  node    $(node --version 2>&1)"
    fi
    if command -v openclaw >/dev/null 2>&1; then
        echo "  openclaw $(openclaw --version 2>&1 | head -1)"
    fi
fi
echo

echo "── INSTALLER_OP_* env vars ──"
env | grep '^INSTALLER_OP_' | sort || echo "(none)"
echo

echo "[noop] DONE — exit 0"
exit 0

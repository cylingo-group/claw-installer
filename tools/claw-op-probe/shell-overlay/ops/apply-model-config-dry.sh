#!/usr/bin/env bash
# apply-model-config-dry.sh — E2E rehearsal for the real apply-model-config.
#
# What the real op script will do:
#   1. source common.sh    (PATH composition; node + openclaw findable)
#   2. read JSON patch from stdin
#   3. openclaw config patch --file <tmp>
#   4. openclaw config validate
#
# What THIS dry-run script does:
#   1. source common.sh    (same as real)
#   2. read JSON patch from stdin (same as real)
#   3. invoke `openclaw --version` (NON-destructive)
#   4. echo the patch back (so user can see it traveled correctly)
#   5. exit 0 without mutating any config
#
# If `openclaw --version` succeeds, that proves the PATH composition works
# and the real op would also find node / openclaw. If it fails with "node:
# not found", we've reproduced the production bug.

set -uo pipefail

echo "════════════════════════════════════════════════════════════════"
echo " apply-model-config-dry.sh — non-destructive E2E rehearsal"
echo "════════════════════════════════════════════════════════════════"

# 1. Source common.sh.
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
    echo "[apply-dry] FAIL: common.sh not found (looked in: ${COMMON_CANDIDATES[*]})"
    exit 2
fi
echo "[apply-dry] sourcing $COMMON"
# shellcheck disable=SC1090
source "$COMMON"
echo "[apply-dry] post-source PATH=$PATH"
echo

# 2. Read patch JSON from stdin.
tmp="$(mktemp /tmp/apply-dry-patch.XXXXXX.json)"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp"
patch_bytes=$(wc -c < "$tmp")
echo "[apply-dry] patch bytes: $patch_bytes"
if [ "$patch_bytes" -lt 1 ]; then
    echo "[apply-dry] WARN: empty patch payload — real flow would fail here"
fi

# 3. Verify openclaw + node are on PATH (the actual bug).
echo
echo "── command resolution ──"
for c in node openclaw; do
    p=$(command -v "$c" 2>/dev/null || echo "(not found)")
    printf "  %-10s %s\n" "$c" "$p"
done

if ! command -v node >/dev/null 2>&1; then
    echo "[apply-dry] FAIL: node not on PATH — this is the production bug"
    exit 3
fi
if ! command -v openclaw >/dev/null 2>&1; then
    echo "[apply-dry] FAIL: openclaw not on PATH — installer hasn't run yet?"
    exit 4
fi

# 4. Invoke openclaw --version (the canary; same shebang path as patch).
echo
echo "── openclaw --version ──"
if openclaw --version 2>&1; then
    echo "[apply-dry] openclaw --version PASSED — production fix would work"
else
    rc=$?
    echo "[apply-dry] FAIL: openclaw --version exit=$rc"
    echo "[apply-dry]       (this is the 'exec: node: not found' bug, manifested elsewhere)"
    exit 5
fi

# 5. Echo the patch back.
echo
echo "── patch payload (echo) ──"
cat "$tmp"
echo

echo "[apply-dry] DONE — exit 0 (no config mutated)"
exit 0

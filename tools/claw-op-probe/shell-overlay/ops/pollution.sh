#!/usr/bin/env bash
# pollution.sh — Verify that our PATH composition wins over a polluted PATH.
#
# Simulates the situation where Windows /mnt/c paths leak a broken `node` or
# `openclaw` into PATH BEFORE common.sh sources. Our prepend logic must put
# the right binaries first.

set -uo pipefail

echo "════════════════════════════════════════════════════════════════"
echo " pollution.sh — PATH pollution resilience test"
echo "════════════════════════════════════════════════════════════════"

# Step 1: create fake binaries that would never work.
FAKE_DIR="/tmp/claw-probe-fake-bin-$$"
mkdir -p "$FAKE_DIR"
trap 'rm -rf "$FAKE_DIR"' EXIT

cat > "$FAKE_DIR/node" <<'EOF'
#!/bin/sh
echo "I AM THE FAKE NODE FROM POLLUTED PATH (this should not be invoked)"
exit 99
EOF
chmod +x "$FAKE_DIR/node"

cat > "$FAKE_DIR/openclaw" <<'EOF'
#!/bin/sh
echo "I AM THE FAKE OPENCLAW FROM POLLUTED PATH (this should not be invoked)"
exit 99
EOF
chmod +x "$FAKE_DIR/openclaw"

cat > "$FAKE_DIR/pnpm" <<'EOF'
#!/bin/sh
echo "I AM THE FAKE PNPM FROM POLLUTED PATH (this should not be invoked)"
exit 99
EOF
chmod +x "$FAKE_DIR/pnpm"

echo "[pollute] fake bin dir: $FAKE_DIR"
ls -la "$FAKE_DIR" | sed 's/^/    /'
echo

# Step 2: pollute PATH (prepend the fake dir, just like /mnt/c paths leak in).
export PATH="$FAKE_DIR:$PATH"
echo "[pollute] PATH now:"
echo "$PATH" | tr ':' '\n' | head -5 | sed 's/^/    /'
echo "    ..."
echo

echo "── command -v BEFORE source common.sh (should resolve to FAKE) ──"
for c in node openclaw pnpm; do
    p="$(command -v "$c" 2>/dev/null || echo '(not found)')"
    printf '  %-10s %s\n' "$c" "$p"
done
echo

# Step 3: source common.sh.
COMMON="$HOME/claw-installer-src/lib/common.sh"
if [ ! -f "$COMMON" ]; then
    echo "[pollute] FATAL: common.sh missing at $COMMON"
    exit 2
fi
echo "── sourcing $COMMON ──"
# shellcheck disable=SC1090
source "$COMMON"
echo "[pollute] source returned $?"
echo

# Clear bash command hash. Without this, command -v hits the cached entries
# from the BEFORE-source check (which all pointed to fake) and reports stale
# results EVEN THOUGH our prepended paths now contain the real binaries.
# In production, op scripts always run in a fresh shell with empty cache, so
# this `hash -r` is purely a test-correctness fix.
hash -r 2>/dev/null || true

echo "── command -v AFTER source + hash -r (FAKE should lose) ──"
losses=0
for c in node openclaw pnpm; do
    p="$(command -v "$c" 2>/dev/null || echo '(not found)')"
    if [[ "$p" == "$FAKE_DIR/"* ]]; then
        printf '  %-10s %s  ← LEAK!\n' "$c" "$p"
        losses=$((losses+1))
    else
        printf '  %-10s %s\n' "$c" "$p"
    fi
done
echo

echo "── PATH AFTER source (first 8 entries) ──"
echo "$PATH" | tr ':' '\n' | head -8 | sed 's/^/    /'
echo

if [ "$losses" -gt 0 ]; then
    echo "[pollute] FAIL: $losses fake binaries still resolve — common.sh did not prepend in front of pollution"
    exit 3
else
    echo "[pollute] PASS: common.sh's prepend won over polluted PATH"
fi

exit 0

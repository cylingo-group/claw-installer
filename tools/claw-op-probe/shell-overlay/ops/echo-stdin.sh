#!/usr/bin/env bash
# echo-stdin.sh — read stdin verbatim, print it back with byte count + md5.
# Used by probe scenarios S* (stdin transport fidelity).

set -uo pipefail

echo "════════════════════════════════════════════════════════════════"
echo " echo-stdin.sh — stdin fidelity check"
echo "════════════════════════════════════════════════════════════════"

# Capture stdin into a tmp file so we can both print + measure it.
tmp="$(mktemp /tmp/echo-stdin.XXXXXX)"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp"

bytes=$(wc -c < "$tmp")
md5=$(md5sum < "$tmp" | awk '{print $1}')

echo "[echo-stdin] bytes:    $bytes"
echo "[echo-stdin] md5:      $md5"
echo "[echo-stdin] content:  <<<EOF"
cat "$tmp"
echo "EOF>>>"

exit 0

#!/usr/bin/env bash
#
# tools/build-linux/run-build.sh — runs inside the Linux build container.
#
# Contract:
#   - /src : repo bind-mounted read-only
#   - /out : dist/linux/ on host, bind-mounted writable
#   - cwd  : /build (Dockerfile WORKDIR), where we materialize a clean copy
#
# Steps:
#   1. rsync repo → /build, excluding node_modules / target / dist so a
#      polluted host tree doesn't poison the Linux build.
#   2. pnpm install (no frozen lockfile — host pnpm version may differ).
#   3. pnpm --filter ./gui tauri build → produces .deb + .AppImage under
#      gui/src-tauri/target/release/bundle/.
#   4. Copy the bundle artifacts to /out so the host can see them.

set -euo pipefail

# pnpm refuses to auto-purge node_modules without a TTY unless CI=true.
# `tauri build` invokes a nested `pnpm install` via beforeBuildCommand, so we
# need this flag to flow through. (Setting confirmModulesPurge=false in
# .npmrc would also work, but CI=true is the standard signal.)
export CI=true

echo "==> rsync /src → /build"
rsync -a \
  --exclude '.git' \
  --exclude 'node_modules' \
  --exclude 'gui/node_modules' \
  --exclude 'gui/dist' \
  --exclude 'gui/src-tauri/target' \
  --exclude 'dist' \
  /src/ /build/

echo "==> pnpm install"
cd /build
pnpm install --no-frozen-lockfile

echo "==> tauri build (linux native arch: $(uname -m))"
pnpm --filter ./gui tauri build

bundle_dir=/build/gui/src-tauri/target/release/bundle
echo "==> copying artifacts from $bundle_dir → /out"
mkdir -p /out
shopt -s nullglob
cp -v "$bundle_dir"/deb/*.deb       /out/ 2>/dev/null || true
cp -v "$bundle_dir"/appimage/*.AppImage /out/ 2>/dev/null || true
cp -v "$bundle_dir"/rpm/*.rpm        /out/ 2>/dev/null || true

echo "==> done"
ls -la /out

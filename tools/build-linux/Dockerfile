# Linux build environment for claw-installer.
#
# Produces Tauri Linux artifacts (.deb + .AppImage) from a macOS host where
# webkit2gtk and the rest of GTK aren't natively available. Targeted by
# `make build-linux`: the Makefile builds this image, then runs it with the
# repo source rsync'd into /build inside the container and dist/linux/
# bind-mounted at /out so artifacts come back to the host.
#
# We pin Ubuntu 24.04 because it ships webkit2gtk-4.1 in apt — the version
# Tauri 2.x links against. Older Ubuntu LTS ships webkit2gtk-4.0 and won't
# work without an extra PPA.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# --- System packages -------------------------------------------------------
# Tauri Linux deps (webkit2gtk-4.1 + GTK + soup-3) + bundling extras
# (librsvg for icon rasterisation, libappindicator for tray) + general build
# toolchain (build-essential, pkg-config, libssl, file for AppImage tooling).
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git rsync xz-utils file \
      build-essential pkg-config \
      libssl-dev \
      libwebkit2gtk-4.1-dev \
      libayatana-appindicator3-dev \
      librsvg2-dev \
      libsoup-3.0-dev \
      libgtk-3-dev \
      libjavascriptcoregtk-4.1-dev \
      patchelf \
      desktop-file-utils \
      libfuse2t64 \
      xdg-utils \
 && rm -rf /var/lib/apt/lists/*

# --- Node 22 + pnpm via corepack ------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && corepack enable \
 && corepack prepare pnpm@10.5.0 --activate

# --- Rust stable -----------------------------------------------------------
# Build for the container's native arch (rustup auto-detects). Callers who
# need a different Linux arch should set `--platform linux/<arch>` on
# `docker build` / `docker run` so the container itself is that arch — that
# way we get a native toolchain (no cross-compile pain, no qemu overhead
# beyond what the platform flag already enables).
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

# Compile artefacts go to a Linux-specific target dir so they don't collide
# with the host macOS target/ when the repo is bind-mounted read-only and
# rsync'd into /build.
ENV CARGO_TARGET_DIR=/build/gui/src-tauri/target

WORKDIR /build

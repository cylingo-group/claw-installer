#!/usr/bin/env bash
# fnm-state.sh — Comprehensive fnm self-diagnosis.
#
# Goal: figure out why _claw_compose_path's _claw_fnm_active_bin returns empty
# on this machine. Asks fnm directly (not via filesystem introspection) so the
# answer doesn't depend on _our_ assumptions about fnm's layout.

set -uo pipefail

echo "════════════════════════════════════════════════════════════════"
echo " fnm-state.sh — fnm self-diagnosis"
echo "════════════════════════════════════════════════════════════════"

# Step 1: locate fnm. Try several places, since common.sh's resolve_fnm_dir
# may not match the actual install.
echo "── Step 1: locate fnm ──"
echo "PATH=$PATH"
echo
for path in \
    "$HOME/.local/share/fnm" \
    "$HOME/.fnm" \
    "$HOME/Library/Application Support/fnm" \
    "${XDG_DATA_HOME:-}/fnm"; do
    [ -z "$path" ] && continue
    if [ -d "$path" ]; then
        echo "[fnm-loc] FOUND fnm dir at: $path"
    else
        echo "[fnm-loc] not present:        $path"
    fi
done
echo

FNM_BIN_PATH="$(command -v fnm 2>/dev/null || echo '')"
echo "[fnm-loc] command -v fnm: ${FNM_BIN_PATH:-(not on PATH)}"

# If fnm isn't on PATH, try the candidates we found.
if [ -z "$FNM_BIN_PATH" ]; then
    for d in "$HOME/.local/share/fnm" "$HOME/.fnm"; do
        if [ -x "$d/fnm" ]; then
            FNM_BIN_PATH="$d/fnm"
            export PATH="$d:$PATH"
            echo "[fnm-loc] found fnm binary at $FNM_BIN_PATH (added to PATH)"
            break
        fi
    done
fi

if [ -z "$FNM_BIN_PATH" ]; then
    echo "[fnm-state] FATAL: cannot locate fnm binary"
    exit 2
fi

echo

# Step 2: ask fnm directly
echo "── Step 2: fnm self-report ──"
echo "[fnm] fnm --version:"
fnm --version 2>&1 | sed 's/^/    /'
echo
echo "[fnm] fnm current (default Node version):"
fnm current 2>&1 | sed 's/^/    /'
echo "[fnm]   exit=$?"
echo
echo "[fnm] fnm list (all installed):"
fnm list 2>&1 | sed 's/^/    /'
echo "[fnm]   exit=$?"
echo
echo "[fnm] fnm env --shell bash (canonical PATH update):"
fnm_env_output="$(fnm env --shell bash 2>&1)"
echo "$fnm_env_output" | sed 's/^/    /'
echo "[fnm]   exit=$?"
echo "[fnm]   output length: ${#fnm_env_output} bytes"
echo
echo "[fnm] fnm exec --using=default -- which node:"
fnm exec --using=default -- which node 2>&1 | sed 's/^/    /'
echo "[fnm]   exit=$?"
echo

# Step 3: filesystem introspection (matches common.sh's _claw_fnm_active_bin)
echo "── Step 3: filesystem layout (matches our introspection) ──"
FNM_DIR_GUESS=""
for d in "$HOME/.local/share/fnm" "$HOME/.fnm"; do
    if [ -d "$d" ]; then
        FNM_DIR_GUESS="$d"
        break
    fi
done
echo "[fs] FNM_DIR (guessed): $FNM_DIR_GUESS"

if [ -n "$FNM_DIR_GUESS" ]; then
    echo
    echo "[fs] $FNM_DIR_GUESS/ contents:"
    ls -la "$FNM_DIR_GUESS/" 2>&1 | sed 's/^/    /'
    echo
    echo "[fs] $FNM_DIR_GUESS/aliases/ contents:"
    if [ -d "$FNM_DIR_GUESS/aliases" ]; then
        ls -la "$FNM_DIR_GUESS/aliases/" 2>&1 | sed 's/^/    /'
        echo
        echo "[fs] readlink \"$FNM_DIR_GUESS/aliases/default\":"
        readlink "$FNM_DIR_GUESS/aliases/default" 2>&1 | sed 's/^/    /'
        echo "[fs]   exit=$?"
        echo "[fs] ls -la \"$FNM_DIR_GUESS/aliases/default\":"
        ls -la "$FNM_DIR_GUESS/aliases/default" 2>&1 | sed 's/^/    /'
        echo "[fs]   is symlink: $([[ -L $FNM_DIR_GUESS/aliases/default ]] && echo yes || echo no)"
    else
        echo "    (aliases/ does NOT exist)"
    fi
    echo
    echo "[fs] $FNM_DIR_GUESS/node-versions/ contents:"
    if [ -d "$FNM_DIR_GUESS/node-versions" ]; then
        ls -la "$FNM_DIR_GUESS/node-versions/" 2>&1 | sed 's/^/    /'
        echo
        # For each installed version, peek into its bin dir
        for ver in "$FNM_DIR_GUESS/node-versions"/*; do
            [ -d "$ver" ] || continue
            echo "[fs] $ver/ contents:"
            ls -la "$ver/" 2>&1 | head -10 | sed 's/^/    /'
            # Check installation/bin (what our common.sh expects)
            if [ -d "$ver/installation/bin" ]; then
                echo "[fs]   ✓ installation/bin exists"
                ls -la "$ver/installation/bin/node" 2>&1 | sed 's/^/      /'
            else
                echo "[fs]   ✗ installation/bin does NOT exist"
                # Look for alternate layouts
                if [ -d "$ver/bin" ]; then
                    echo "[fs]   …but $ver/bin exists (alternate layout)"
                    ls -la "$ver/bin/node" 2>&1 | sed 's/^/      /'
                fi
            fi
        done
    else
        echo "    (node-versions/ does NOT exist)"
    fi
fi

echo
echo "── Step 4: simulated PATH after fnm env eval ──"
eval "$(fnm env --shell bash 2>/dev/null)" || true
echo "[sim] PATH after eval: (first 5 entries)"
echo "$PATH" | tr ':' '\n' | head -5 | sed 's/^/    /'
echo
echo "[sim] command -v node: $(command -v node 2>/dev/null || echo '(not found)')"
echo "[sim] command -v openclaw: $(command -v openclaw 2>/dev/null || echo '(not found)')"
if command -v node >/dev/null 2>&1; then
    echo "[sim] node --version: $(node --version 2>&1)"
fi

echo
echo "[fnm-state] DONE — exit 0"
exit 0

#!/usr/bin/env bash
# lib/manifest.sh — record the side effects of an install run so uninstall.sh
# can reverse exactly what we did (and skip what was already on the host).
# Sourced by lib/common.sh.
#
# NOTE: setup_install_log() has been removed. The session log is managed
# entirely via the CLAW_SESSION_LOG env var set by Rust (or auto-generated
# as a fallback in common.sh). CLAW_INSTALL_LOG is deprecated and unused.

# State dir is intentionally separate from ~/.openclaw — that directory
# belongs to the openclaw runtime and may be wiped/recreated by it. We need
# our manifest to survive across openclaw resets.
export CLAW_STATE_DIR="${CLAW_STATE_DIR:-$HOME/.claw-installer}"
export CLAW_MANIFEST="${CLAW_MANIFEST:-$CLAW_STATE_DIR/manifest.tsv}"

manifest_init() {
  mkdir -p "$CLAW_STATE_DIR"
  if [[ ! -f "$CLAW_MANIFEST" ]]; then
    {
      echo "# claw-installer manifest — auto-generated, do not edit by hand."
      echo "# fields: timestamp<TAB>action<TAB>target<TAB>status<TAB>note"
    } > "$CLAW_MANIFEST"
  fi
  log "Manifest: $CLAW_MANIFEST"
}

# manifest_record <action> <target> [status] [note]
#   First-write wins: if a row with the same (action, target) already exists,
#   we keep the original status. That makes re-runs idempotent and preserves
#   the "preexisting" verdict from the very first install.
manifest_record() {
  manifest_init
  local action="$1" target="$2" status="${3:-installed}" note="${4:-}"
  if [[ -f "$CLAW_MANIFEST" ]] \
     && awk -F'\t' -v a="$action" -v t="$target" \
          '$2==a && $3==t {f=1} END{exit !f}' "$CLAW_MANIFEST"; then
    return 0
  fi
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$action" "$target" "$status" "$note" \
    >> "$CLAW_MANIFEST"
}

# manifest_query <action>  → "<target>\t<status>\t<note>" lines, insertion order.
manifest_query() {
  local action="$1"
  [[ -f "$CLAW_MANIFEST" ]] || return 0
  awk -F'\t' -v a="$action" '$2==a { print $3 "\t" $4 "\t" $5 }' "$CLAW_MANIFEST"
}

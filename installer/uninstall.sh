#!/usr/bin/env bash
# uninstall.sh — reverse what install.sh did, based on the install manifest.
#
# Reads ~/.claw-installer/manifest.tsv (path configurable via
# CLAW_MANIFEST) and undoes each recorded action in reverse order. Actions
# whose status is "preexisting" are left alone — we only remove things we
# actually installed.
#
# Flags:
#   --dry-run            Show the plan, change nothing.
#   --yes                Skip the confirmation prompt.
#   --purge-workspace    Also delete openclaw_workspace entries
#                         (default: keep — workspace may hold user data).
#   --purge-hermes-home  Also delete the hermes_home dir ($HERMES_HOME)
#                         (default: keep — may hold .env / SOUL.md / sessions).
#   --purge-all          Shorthand for --purge-workspace + --purge-hermes-home.
#   --keep-manifest      Don't delete the manifest after a successful run.

set -euo pipefail

__DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$__DIR/lib/common.sh"

DRY_RUN=0
ASSUME_YES=0
PURGE_WORKSPACE=0
PURGE_HERMES_HOME=0
KEEP_MANIFEST=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)            DRY_RUN=1 ;;
    --yes|-y)             ASSUME_YES=1 ;;
    --purge-workspace)    PURGE_WORKSPACE=1 ;;
    --purge-hermes-home)  PURGE_HERMES_HOME=1 ;;
    --purge-all)          PURGE_WORKSPACE=1; PURGE_HERMES_HOME=1 ;;
    --keep-manifest)      KEEP_MANIFEST=1 ;;
    -h|--help)
      sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "Unknown flag: $arg (try --help)" ;;
  esac
done

[[ -f "$CLAW_MANIFEST" ]] || die "No manifest at $CLAW_MANIFEST — nothing to uninstall (or installer never ran)."

# run_cmd <cmd...>  — execute or just print under --dry-run
run_cmd() {
  if (( DRY_RUN )); then
    printf '  [dry-run] %s\n' "$*"
  else
    log "  $*"
    "$@" || warn "  (command failed — continuing)"
  fi
}

# strip_sentinel_block <rc-file> <begin> <end>
strip_sentinel_block() {
  local rc="$1" b="$2" e="$3"
  [[ -f "$rc" ]] || { log "  (already gone: $rc)"; return; }
  if (( DRY_RUN )); then
    printf '  [dry-run] strip managed block from %s\n' "$rc"
    return
  fi
  local tmp
  tmp="$(mktemp)"
  awk -v b="$b" -v e="$e" '
    BEGIN { skip = 0 }
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    skip == 0 { print }
  ' "$rc" > "$tmp"
  mv "$tmp" "$rc"
  log "  stripped managed block from $rc"
}

# Iterate manifest rows in REVERSE insertion order. Each non-comment row is
# tab-separated: timestamp\taction\ttarget\tstatus\tnote.
rows_reverse() {
  awk -F'\t' '!/^#/ && NF >= 4 { print }' "$CLAW_MANIFEST" \
    | awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}'
}

declare -a SYSTEM_PKG_NOTES=()

plan_summary() {
  # Colored action tags. All padded to 6 chars between brackets so columns
  # line up. Colors disabled automatically when stdout isn't a TTY.
  local C_RESET='' T_REMOVE='[remove]' T_STRIP='[strip ]' T_KEEP='[keep  ]'
  local T_SKIP='[skip  ]' T_NOTE='[note  ]' T_UNK='[?unkwn]'
  if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    T_REMOVE=$'\033[1;31m[remove]'"$C_RESET"   # red
    T_STRIP=$'\033[1;33m[strip ]'"$C_RESET"    # yellow
    T_KEEP=$'\033[1;32m[keep  ]'"$C_RESET"     # green
    T_SKIP=$'\033[1;30m[skip  ]'"$C_RESET"     # dim grey
    T_NOTE=$'\033[1;36m[note  ]'"$C_RESET"     # cyan
    T_UNK=$'\033[1;35m[?unkwn]'"$C_RESET"      # magenta
  fi

  echo
  echo "Will reverse the following recorded actions (newest first):"
  echo "  Manifest:           $CLAW_MANIFEST"
  echo "  Purge workspace?    $(( PURGE_WORKSPACE )) (use --purge-workspace to enable)"
  echo "  Purge hermes-home?  $(( PURGE_HERMES_HOME )) (use --purge-hermes-home to enable)"
  echo
  while IFS=$'\t' read -r ts action target status note; do
    case "$action" in
      system_pkg)
        printf '  %s system pkg %-20s (%s) — left in place\n' "$T_SKIP" "$target" "$status"
        ;;
      fnm_binary)
        if [[ "$status" == "preexisting" ]]; then
          printf '  %s fnm at %s (preexisting)\n' "$T_SKIP" "$target"
        else
          printf '  %s fnm dir %s\n' "$T_REMOVE" "$target"
        fi
        ;;
      fnm_node)
        if [[ "$status" == "preexisting" ]]; then
          printf '  %s node v%s (preexisting)\n' "$T_SKIP" "$target"
        else
          printf '  %s fnm node v%s\n' "$T_REMOVE" "$target"
        fi
        ;;
      pnpm_global_pkg)
        printf '  %s pnpm global pkg %s\n' "$T_REMOVE" "$target"
        ;;
      corepack_pnpm)
        printf '  %s %s was activated via corepack (left in place)\n' "$T_NOTE" "$target"
        ;;
      pnpm_home)
        if [[ "$status" == "preexisting" ]]; then
          printf '  %s PNPM_HOME %s (preexisting)\n' "$T_SKIP" "$target"
        else
          printf '  %s PNPM_HOME %s\n' "$T_REMOVE" "$target"
        fi
        ;;
      npmrc_block|shell_rc_block)
        printf '  %s managed block from %s\n' "$T_STRIP" "$target"
        ;;
      openclaw_service)
        printf '  %s openclaw service: %s\n' "$T_REMOVE" "$target"
        ;;
      openclaw_config_file)
        printf '  %s openclaw config file %s\n' "$T_REMOVE" "$target"
        ;;
      openclaw_workspace)
        if [[ "$status" == "preexisting" ]]; then
          printf '  %s openclaw workspace %s (preexisting — not ours to remove)\n' "$T_KEEP" "$target"
        elif (( PURGE_WORKSPACE )); then
          printf '  %s openclaw workspace %s\n' "$T_REMOVE" "$target"
        else
          printf '  %s openclaw workspace %s (use --purge-workspace to remove)\n' "$T_KEEP" "$target"
        fi
        ;;
      uv_binary)
        if [[ "$status" == "preexisting" ]]; then
          printf '  %s uv at %s (preexisting)\n' "$T_SKIP" "$target"
        else
          printf '  %s uv binary %s\n' "$T_REMOVE" "$target"
        fi
        ;;
      uv_python)
        if [[ "$status" == "preexisting" ]]; then
          printf '  %s uv-managed Python %s (preexisting)\n' "$T_SKIP" "$target"
        else
          printf '  %s uv python uninstall %s\n' "$T_REMOVE" "$target"
        fi
        ;;
      hermes_node_symlink)
        if [[ "$status" == "preexisting" ]]; then
          printf '  %s hermes Node dir %s (preexisting, owned by hermes)\n' "$T_SKIP" "$target"
        else
          printf '  %s hermes Node symlink dir %s\n' "$T_REMOVE" "$target"
        fi
        ;;
      hermes_install_dir)
        if [[ "$status" == "preexisting" ]]; then
          printf '  %s hermes install dir %s (preexisting)\n' "$T_SKIP" "$target"
        else
          printf '  %s hermes install dir %s\n' "$T_REMOVE" "$target"
        fi
        ;;
      hermes_bin)
        if [[ "$status" == "preexisting" ]]; then
          printf '  %s hermes binary %s (preexisting)\n' "$T_SKIP" "$target"
        else
          printf '  %s hermes binary %s\n' "$T_REMOVE" "$target"
        fi
        ;;
      hermes_home)
        if [[ "$status" == "preexisting" ]]; then
          printf '  %s hermes home %s (preexisting — not ours to remove)\n' "$T_KEEP" "$target"
        elif (( PURGE_HERMES_HOME )); then
          printf '  %s hermes home %s\n' "$T_REMOVE" "$target"
        else
          printf '  %s hermes home %s (use --purge-hermes-home to remove)\n' "$T_KEEP" "$target"
        fi
        ;;
      *) printf '  %s %s %s\n' "$T_UNK" "$action" "$target" ;;
    esac
  done < <(rows_reverse)
  echo
}

apply_uninstall() {
  while IFS=$'\t' read -r ts action target status note; do
    case "$action" in
      system_pkg)
        SYSTEM_PKG_NOTES+=("$target ($status)")
        ;;
      fnm_binary)
        [[ "$status" == "preexisting" ]] && continue
        [[ -d "$target" ]] || { log "  fnm dir already gone: $target"; continue; }
        run_cmd rm -rf "$target"
        ;;
      fnm_node)
        [[ "$status" == "preexisting" ]] && continue
        if command -v fnm >/dev/null 2>&1; then
          run_cmd fnm uninstall "$target"
        else
          warn "  fnm not on PATH — cannot uninstall node v$target"
        fi
        ;;
      pnpm_global_pkg)
        if command -v pnpm >/dev/null 2>&1; then
          run_cmd pnpm rm -g "$target"
        else
          warn "  pnpm not on PATH — cannot remove global pkg $target"
        fi
        ;;
      corepack_pnpm)
        log "  corepack pnpm activation left in place (corepack ships with Node)"
        ;;
      pnpm_home)
        [[ "$status" == "preexisting" ]] && continue
        [[ -d "$target" ]] || { log "  PNPM_HOME already gone: $target"; continue; }
        run_cmd rm -rf "$target"
        ;;
      npmrc_block)
        strip_sentinel_block "$target" "$NPMRC_SENTINEL_BEGIN" "$NPMRC_SENTINEL_END"
        ;;
      shell_rc_block)
        strip_sentinel_block "$target" "$SHELL_RC_SENTINEL_BEGIN" "$SHELL_RC_SENTINEL_END"
        ;;
      openclaw_service)
        if command -v openclaw >/dev/null 2>&1; then
          run_cmd openclaw gateway stop
          run_cmd openclaw gateway uninstall
        else
          warn "  openclaw not on PATH — cannot stop/uninstall service $target"
        fi
        ;;
      openclaw_config_file)
        [[ -e "$target" ]] || { log "  config already gone: $target"; continue; }
        run_cmd rm -f "$target"
        ;;
      openclaw_workspace)
        if (( PURGE_WORKSPACE )) && [[ "$status" != "preexisting" ]]; then
          [[ -d "$target" ]] || { log "  workspace already gone: $target"; continue; }
          run_cmd rm -rf "$target"
        else
          log "  keeping workspace: $target"
        fi
        ;;
      uv_binary)
        [[ "$status" == "preexisting" ]] && continue
        [[ -e "$target" ]] || { log "  uv binary already gone: $target"; continue; }
        run_cmd rm -f "$target"
        ;;
      uv_python)
        [[ "$status" == "preexisting" ]] && continue
        if command -v uv >/dev/null 2>&1; then
          run_cmd uv python uninstall "$target"
        else
          warn "  uv not on PATH — cannot uninstall Python $target (uv binary may already be removed)"
        fi
        ;;
      hermes_node_symlink)
        [[ "$status" == "preexisting" ]] && continue
        [[ -d "$target" ]] || { log "  hermes node dir already gone: $target"; continue; }
        run_cmd rm -rf "$target"
        ;;
      hermes_install_dir)
        [[ "$status" == "preexisting" ]] && continue
        [[ -d "$target" ]] || { log "  hermes install dir already gone: $target"; continue; }
        run_cmd rm -rf "$target"
        ;;
      hermes_bin)
        [[ "$status" == "preexisting" ]] && continue
        [[ -e "$target" ]] || { log "  hermes binary already gone: $target"; continue; }
        run_cmd rm -f "$target"
        ;;
      hermes_home)
        if (( PURGE_HERMES_HOME )) && [[ "$status" != "preexisting" ]]; then
          [[ -d "$target" ]] || { log "  hermes home already gone: $target"; continue; }
          run_cmd rm -rf "$target"
        else
          log "  keeping hermes home: $target"
        fi
        ;;
      *) warn "  unknown manifest action: $action $target" ;;
    esac
  done < <(rows_reverse)
}

print_followup() {
  echo
  echo "==============================================================================="
  echo "  Uninstall complete."
  if [[ -n "${CLAW_INSTALL_LOG:-}" ]]; then
    echo "  This run logged to: $CLAW_INSTALL_LOG"
  fi
  if (( ${#SYSTEM_PKG_NOTES[@]} > 0 )); then
    echo
    echo "  系统共享依赖未被移除（避免影响其他软件）。如需手动清理，曾被本安装器触及："
    local p
    for p in "${SYSTEM_PKG_NOTES[@]}"; do
      echo "    - $p"
    done
  fi
  if (( ! PURGE_WORKSPACE )); then
    echo
    echo "  OpenClaw workspace 已保留。要一并清除请使用：./uninstall.sh --purge-workspace"
  fi
  if (( ! PURGE_HERMES_HOME )); then
    echo "  Hermes home (~/.hermes) 已保留。要一并清除请使用：./uninstall.sh --purge-hermes-home"
    echo "  注意：上游脚本写入 ~/.bashrc / ~/.zshrc / ~/.profile 的 ~/.local/bin PATH 行无 sentinel，"
    echo "        如需移除请手动检查 rc 文件。"
  fi
  echo "==============================================================================="
}

main() {
  plan_summary
  if (( DRY_RUN )); then
    log "Dry run — no changes made."
    return
  fi
  if (( ! ASSUME_YES )); then
    read -r -p "Proceed with uninstall? [y/N] " ans
    case "$ans" in
      y|Y|yes|YES) ;;
      *) die "Aborted." ;;
    esac
  fi
  apply_uninstall
  if (( ! KEEP_MANIFEST )); then
    run_cmd rm -f "$CLAW_MANIFEST"
    # State dir may still contain install logs — leave it for forensic use.
  fi
  print_followup
}

main "$@"

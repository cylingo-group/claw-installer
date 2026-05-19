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
#   --debug              Tail the session log to stderr in real time.
#   --purge-workspace    Also delete openclaw_workspace entries
#                         (default: keep — workspace may hold user data).
#   --purge-hermes-home  Also delete the hermes_home dir ($HERMES_HOME)
#                         (default: keep — may hold .env / SOUL.md / sessions).
#   --purge-all          Shorthand for --purge-workspace + --purge-hermes-home.
#   --keep-manifest      Don't delete the manifest after a successful run.
#
# Environment toggles:
#   CLAW_UNINSTALL_AGENT=openclaw|hermes
#     Filter mode: only reverse manifest rows specific to this agent.
#     Shared env (fnm/pnpm/node/npmrc/shell-rc/system pkgs) is left intact.
#     The manifest is rewritten to remove the agent's rows but kept on disk
#     if anything remains for the other agent.

set -euo pipefail

__DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$__DIR/lib/common.sh"

DRY_RUN=0
ASSUME_YES=0
PURGE_WORKSPACE=0
PURGE_HERMES_HOME=0
KEEP_MANIFEST=0
DEBUG_MODE=0
AGENT_FILTER="${CLAW_UNINSTALL_AGENT:-}"

# row_matches_filter <action> <target>
#   When AGENT_FILTER is empty, every row matches (full teardown).
#   Otherwise, only rows belonging to the named agent match:
#     openclaw: openclaw_service / openclaw_config_file / openclaw_workspace
#               pnpm_global_pkg with target=openclaw
#     hermes:   hermes_* + uv_binary + uv_python
row_matches_filter() {
  local action="$1" target="$2"
  [[ -z "$AGENT_FILTER" ]] && return 0
  case "$AGENT_FILTER" in
    openclaw)
      case "$action" in
        openclaw_service|openclaw_config_file|openclaw_workspace) return 0 ;;
        pnpm_global_pkg) [[ "$target" == "openclaw" ]] && return 0 ;;
      esac
      return 1
      ;;
    hermes)
      case "$action" in
        hermes_install_dir|hermes_home|hermes_bin|hermes_node_symlink) return 0 ;;
        uv_binary|uv_python) return 0 ;;
      esac
      return 1
      ;;
    *)
      die_step "卸载过滤" "Unknown CLAW_UNINSTALL_AGENT value: $AGENT_FILTER (expected: openclaw|hermes)" 1
      ;;
  esac
}

for arg in "$@"; do
  case "$arg" in
    --dry-run)            DRY_RUN=1 ;;
    --yes|-y)             ASSUME_YES=1 ;;
    --debug)              DEBUG_MODE=1 ;;
    --purge-workspace)    PURGE_WORKSPACE=1 ;;
    --purge-hermes-home)  PURGE_HERMES_HOME=1 ;;
    --purge-all)          PURGE_WORKSPACE=1; PURGE_HERMES_HOME=1 ;;
    --keep-manifest)      KEEP_MANIFEST=1 ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die_step "参数解析" "Unknown flag: $arg (try --help)" 1 ;;
  esac
done

# Missing manifest is NOT a failure — it means there's nothing to undo.
# Either the installer was never run, or a previous uninstall already cleaned
# everything up. Exit success so the GUI flips the agent back to "未安装".
if [[ ! -f "$CLAW_MANIFEST" ]]; then
  display "没有可卸载的内容（未发现安装记录）"
  log "No manifest at $CLAW_MANIFEST — exiting 0 (nothing to do)"
  exit 0
fi

# run_cmd <cmd...>  — execute or just print under --dry-run
run_cmd() {
  if (( DRY_RUN )); then
    display "  [dry-run] $*"
  else
    log "  $*"
    run "$@" || log "  (command failed — continuing)"
  fi
}

# strip_sentinel_block <rc-file> <begin> <end>
strip_sentinel_block() {
  local rc="$1" b="$2" e="$3"
  [[ -f "$rc" ]] || { log "  (already gone: $rc)"; return; }
  if (( DRY_RUN )); then
    display "  [dry-run] strip managed block from $rc"
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
  display "@@step:uninstall-plan:正在生成卸载计划…"
  local C_RESET='' T_REMOVE='[remove]' T_STRIP='[strip ]' T_KEEP='[keep  ]'
  local T_SKIP='[skip  ]' T_NOTE='[note  ]' T_UNK='[?unkwn]'
  if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    T_REMOVE=$'\033[1;31m[remove]'"$C_RESET"
    T_STRIP=$'\033[1;33m[strip ]'"$C_RESET"
    T_KEEP=$'\033[1;32m[keep  ]'"$C_RESET"
    T_SKIP=$'\033[1;30m[skip  ]'"$C_RESET"
    T_NOTE=$'\033[1;36m[note  ]'"$C_RESET"
    T_UNK=$'\033[1;35m[?unkwn]'"$C_RESET"
  fi

  display ""
  display "将按以下计划卸载（最新优先）："
  display "  Manifest:           $CLAW_MANIFEST"
  display "  Agent filter:       ${AGENT_FILTER:-<全部>}"
  display "  Purge workspace?    $(( PURGE_WORKSPACE )) (use --purge-workspace to enable)"
  display "  Purge hermes-home?  $(( PURGE_HERMES_HOME )) (use --purge-hermes-home to enable)"
  display ""
  while IFS=$'\t' read -r _ts action target status _note; do
    row_matches_filter "$action" "$target" || continue
    case "$action" in
      system_pkg)
        display "  $T_SKIP system pkg $target ($status) — left in place"
        ;;
      fnm_binary)
        if [[ "$status" == "preexisting" ]]; then
          display "  $T_SKIP fnm at $target (preexisting)"
        else
          display "  $T_REMOVE fnm dir $target"
        fi
        ;;
      fnm_node)
        if [[ "$status" == "preexisting" ]]; then
          display "  $T_SKIP node v$target (preexisting)"
        else
          display "  $T_REMOVE fnm node v$target"
        fi
        ;;
      pnpm_global_pkg)
        display "  $T_REMOVE pnpm global pkg $target"
        ;;
      corepack_pnpm)
        display "  $T_NOTE $target was activated via corepack (left in place)"
        ;;
      pnpm_home)
        if [[ "$status" == "preexisting" ]]; then
          display "  $T_SKIP PNPM_HOME $target (preexisting)"
        else
          display "  $T_REMOVE PNPM_HOME $target"
        fi
        ;;
      npmrc_block|shell_rc_block)
        display "  $T_STRIP managed block from $target"
        ;;
      openclaw_service)
        display "  $T_REMOVE openclaw service: $target"
        ;;
      openclaw_config_file)
        display "  $T_REMOVE openclaw config file $target"
        ;;
      openclaw_workspace)
        if [[ "$status" == "preexisting" ]]; then
          display "  $T_KEEP openclaw workspace $target (preexisting — not ours to remove)"
        elif (( PURGE_WORKSPACE )); then
          display "  $T_REMOVE openclaw workspace $target"
        else
          display "  $T_KEEP openclaw workspace $target (use --purge-workspace to remove)"
        fi
        ;;
      uv_binary)
        if [[ "$status" == "preexisting" ]]; then
          display "  $T_SKIP uv at $target (preexisting)"
        else
          display "  $T_REMOVE uv binary $target"
        fi
        ;;
      uv_python)
        if [[ "$status" == "preexisting" ]]; then
          display "  $T_SKIP uv-managed Python $target (preexisting)"
        else
          display "  $T_REMOVE uv python uninstall $target"
        fi
        ;;
      hermes_node_symlink)
        if [[ "$status" == "preexisting" ]]; then
          display "  $T_SKIP hermes Node dir $target (preexisting, owned by hermes)"
        else
          display "  $T_REMOVE hermes Node symlink dir $target"
        fi
        ;;
      hermes_install_dir)
        if [[ "$status" == "preexisting" ]]; then
          display "  $T_SKIP hermes install dir $target (preexisting)"
        else
          display "  $T_REMOVE hermes install dir $target"
        fi
        ;;
      hermes_bin)
        if [[ "$status" == "preexisting" ]]; then
          display "  $T_SKIP hermes binary $target (preexisting)"
        else
          display "  $T_REMOVE hermes binary $target"
        fi
        ;;
      hermes_home)
        if [[ "$status" == "preexisting" ]]; then
          display "  $T_KEEP hermes home $target (preexisting — not ours to remove)"
        elif (( PURGE_HERMES_HOME )); then
          display "  $T_REMOVE hermes home $target"
        else
          display "  $T_KEEP hermes home $target (use --purge-hermes-home to remove)"
        fi
        ;;
      *) display "  $T_UNK $action $target" ;;
    esac
  done < <(rows_reverse)
  display ""
}

apply_uninstall() {
  display "@@step:uninstall-apply:正在执行卸载操作…"
  while IFS=$'\t' read -r _ts action target status _note; do
    row_matches_filter "$action" "$target" || continue
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
          log "  fnm not on PATH — cannot uninstall node v$target"
        fi
        ;;
      pnpm_global_pkg)
        if command -v pnpm >/dev/null 2>&1; then
          run_cmd pnpm rm -g "$target"
        else
          log "  pnpm not on PATH — cannot remove global pkg $target"
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
          log "  openclaw not on PATH — cannot stop/uninstall service $target"
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
          log "  uv not on PATH — cannot uninstall Python $target (uv binary may already be removed)"
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
      *) log "  unknown manifest action: $action $target" ;;
    esac
  done < <(rows_reverse)
}

print_followup() {
  display "✓ 卸载完成"
  display "  日志：$CLAW_SESSION_LOG"
  if (( ${#SYSTEM_PKG_NOTES[@]} > 0 )); then
    display ""
    display "  系统共享依赖未被移除（避免影响其他软件）。如需手动清理，曾被本安装器触及："
    local p
    for p in "${SYSTEM_PKG_NOTES[@]}"; do
      log "    - $p"
    done
  fi
  if (( ! PURGE_WORKSPACE )); then
    display ""
    display "  OpenClaw workspace 已保留。要一并清除请使用：./uninstall.sh --purge-workspace"
  fi
  if (( ! PURGE_HERMES_HOME )); then
    display "  Hermes home (~/.hermes) 已保留。要一并清除请使用：./uninstall.sh --purge-hermes-home"
    log "  注意：上游脚本写入 ~/.bashrc / ~/.zshrc / ~/.profile 的 ~/.local/bin PATH 行无 sentinel，"
    log "        如需移除请手动检查 rc 文件。"
  fi
}

main() {
  # Start debug tail if requested (fd 3 was opened when common.sh was sourced)
  if (( DEBUG_MODE )); then
    display "日志文件：$CLAW_SESSION_LOG"
    tail -F "$CLAW_SESSION_LOG" >&2 &
    TAIL_PID=$!
    trap 'kill "$TAIL_PID" 2>/dev/null || true' EXIT
  fi

  trap 'die_step_handler' ERR

  plan_summary
  if (( DRY_RUN )); then
    log "Dry run — no changes made."
    display "试运行完成，未做任何更改。"
    return
  fi
  if (( ! ASSUME_YES )); then
    read -r -p "Proceed with uninstall? [y/N] " ans
    case "$ans" in
      y|Y|yes|YES) ;;
      *) die_step "卸载确认" "Aborted by user." 1 ;;
    esac
  fi
  apply_uninstall
  if (( ! KEEP_MANIFEST )); then
    if [[ -z "$AGENT_FILTER" ]]; then
      run_cmd rm -f "$CLAW_MANIFEST"
      # State dir may still contain other files — leave it for forensic use.
    else
      # Rewrite manifest: keep header + every row that did NOT match the filter.
      # If nothing remains other than the header, drop the file too.
      local tmp keep
      tmp="$(mktemp)"
      keep=0
      while IFS= read -r line; do
        # Pass through comments / blank lines.
        if [[ "$line" == \#* || -z "$line" ]]; then
          printf '%s\n' "$line" >>"$tmp"
          continue
        fi
        IFS=$'\t' read -r _ts action target _status _note <<<"$line"
        if row_matches_filter "$action" "$target"; then
          continue
        fi
        printf '%s\n' "$line" >>"$tmp"
        keep=$(( keep + 1 ))
      done <"$CLAW_MANIFEST"
      if (( keep > 0 )); then
        mv "$tmp" "$CLAW_MANIFEST"
        log "Manifest rewritten ($keep remaining rows)"
      else
        rm -f "$tmp" "$CLAW_MANIFEST"
        log "Manifest empty after filter — removed"
      fi
    fi
  fi
  print_followup
}

main "$@"

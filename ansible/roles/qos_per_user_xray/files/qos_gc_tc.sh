#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date '+%F %T')] $*"; }

# ============================================================
# Helpers
# ============================================================
need_cmd() { command -v "$1" >/dev/null 2>&1; }

norm_hex4() {
  local h="${1,,}"
  h="${h#0x}"
  [[ "$h" =~ ^[0-9a-f]+$ ]] || return 1
  printf "%04x" "$((16#$h))"
}

detect_wan_dev() {
  if need_cmd ip; then
    local dev
    dev="$(ip -o -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    [[ -n "$dev" ]] && { echo "$dev"; return 0; }
    dev="$(ip -o -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    [[ -n "$dev" ]] && { echo "$dev"; return 0; }
  fi
  echo "eth0"
}

run_cmd() {
  if [[ "${QOS_GC_DRY_RUN:-0}" == "1" ]]; then
    log "DRY_RUN: $*"
    return 0
  fi
  "$@"
}

# ============================================================
# Config
# ============================================================
QOS_ENV_FILE="${QOS_ENV_FILE:-/etc/qos/qos.env}"
[[ -f "$QOS_ENV_FILE" ]] || QOS_ENV_FILE="/usr/local/etc/qos.env"
[[ -f "$QOS_ENV_FILE" ]] && source "$QOS_ENV_FILE"

WAN_DEV="${WAN_DEV:-}"
[[ "${WAN_DEV:-}" == "auto" ]] && WAN_DEV=""
IFB_DEV="${IFB_DEV:-ifb0}"
[[ -z "$WAN_DEV" ]] && WAN_DEV="$(detect_wan_dev)"

UL_ROOT="${UL_ROOT:-1}"
DL_ROOT="${DL_ROOT:-2}"

QOS_GC_ENABLE="${QOS_GC_ENABLE:-1}"
QOS_GC_IDLE_SEC="${QOS_GC_IDLE_SEC:-14400}"      # 4h
QOS_GC_MIN_AGE_SEC="${QOS_GC_MIN_AGE_SEC:-600}"  # 10m
QOS_GC_USE_CONNTRACK="${QOS_GC_USE_CONNTRACK:-0}"
QOS_GC_DRY_RUN="${QOS_GC_DRY_RUN:-0}"

STATE_DIR="${STATE_DIR:-/var/lib/qos-gc}"
STATE_FILE="$STATE_DIR/state.tsv"
LOCK_FILE="/run/qos-gc.lock"

KEEP_CLASSIDS=(
  "${UL_ROOT}:1" "${DL_ROOT}:1"
  "${UL_ROOT}:fffe" "${DL_ROOT}:fffe"
)

mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

# ============================================================
# State
# ============================================================
declare -A first_seen last_seen ul_bytes dl_bytes

load_state() {
  while IFS=$'\t' read -r h fs ls ub db; do
    [[ -n "${h:-}" ]] || continue
    first_seen["$h"]="$fs"
    last_seen["$h"]="$ls"
    ul_bytes["$h"]="$ub"
    dl_bytes["$h"]="$db"
  done < "$STATE_FILE"
}

save_state() {
  : > "$STATE_FILE.tmp"
  for h in "${!first_seen[@]}"; do
    printf "%s\t%s\t%s\t%s\t%s\n" \
      "$h" "${first_seen[$h]}" "${last_seen[$h]}" \
      "${ul_bytes[$h]}" "${dl_bytes[$h]}" \
      >> "$STATE_FILE.tmp"
  done
  mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

# ============================================================
# tc helpers
# ============================================================
list_classes_bytes() {
  local dev="$1" root="$2"
  tc -s class show dev "$dev" 2>/dev/null \
  | awk -v root="${root}:" '
      $1=="class" && $2=="htb" && index($3, root)==1 {
        cid=$3; bytes=0
        for(i=1;i<=NF;i++) if($i=="Sent"){bytes=$(i+1)}
        print cid "\t" bytes
      }'
}

is_kept_classid() {
  local cid="$1"
  for k in "${KEEP_CLASSIDS[@]}"; do
    [[ "$cid" == "$k" ]] && return 0
  done
  return 1
}

delete_filters_for_mark() {
  local dev="$1" root="$2" hex4="$3"
  local cls="${root}:${hex4}" mark="0x${hex4,,}"

  tc filter show dev "$dev" parent "${root}:" 2>/dev/null \
  | awk -v cls="$cls" -v mark="$mark" '
      $1=="filter" && $2=="protocol" {
        proto=$3; pref=""
        for(i=1;i<=NF;i++) if($i=="pref") pref=$(i+1)
        if (pref!="" && (index($0, cls)>0 || index($0, mark)>0)) {
          print pref "\t" proto
        }
      }' \
  | while IFS=$'\t' read -r pref proto; do
      [[ -n "$pref" && -n "$proto" ]] || continue
      log "del filter: dev=$dev parent=${root}: pref=$pref proto=$proto (mark=0x$hex4)"
      run_cmd tc filter del dev "$dev" parent "${root}:" pref "$pref" protocol "$proto" 2>/dev/null || true
    done
}

delete_class_if_exists() {
  local dev="$1" classid="$2"
  log "del class: dev=$dev classid=$classid"
  run_cmd tc class del dev "$dev" classid "$classid" 2>/dev/null || true
}

# ============================================================
# Dangling fw-filter GC (classid missing) - matches your output
# ============================================================
gc_dangling_fw_filters() {
  local dev="$1" root="$2"
  local removed=0

  local classes
  classes="$(tc class show dev "$dev" 2>/dev/null | awk '$1=="class" && $2=="htb"{print $3}' | tr '\n' ' ')"

  tc filter show dev "$dev" parent "${root}:" 2>/dev/null \
  | awk -v root="${root}:" '
      $1=="filter" && $2=="protocol" {
        proto=$3; pref=""; classid=""
        for(i=1;i<=NF;i++){
          if($i=="pref") pref=$(i+1)
          if($i=="classid") classid=$(i+1)
        }
        if(pref!="" && classid!="" && index(classid, root)==1)
          print pref "\t" proto "\t" classid
      }' \
  | while IFS=$'\t' read -r pref proto classid; do
      [[ -n "$pref" && -n "$proto" && -n "$classid" ]] || continue
      is_kept_classid "$classid" && continue
      if ! grep -qw "$classid" <<<"$classes"; then
        log "del dangling fw-filter: dev=$dev parent=${root}: pref=$pref proto=$proto (classid=$classid missing)"
        run_cmd tc filter del dev "$dev" parent "${root}:" pref "$pref" protocol "$proto" 2>/dev/null || true
        removed=$((removed+1))
      fi
    done

  echo "$removed"
}

# ============================================================
# conntrack (fast check for 1.4.8)
# ============================================================
conntrack_has_mark() {
  local hex4="$1"
  local mark="0x${hex4,,}"
  need_cmd conntrack || return 0
  conntrack -L -m "$mark" 2>/dev/null | head -n 1 | grep -q .
}

# ============================================================
# Main
# ============================================================
main() {
  [[ "$QOS_GC_ENABLE" == "1" ]] || { log "GC disabled"; exit 0; }
  need_cmd tc || { log "tc not found"; exit 1; }

  exec 9>"$LOCK_FILE"
  flock -n 9 || { log "GC already running"; exit 0; }

  local now; now="$(date +%s)"

  # Counters
  local cnt_ul_lines=0 cnt_dl_lines=0
  local cnt_unique_marks=0
  local cnt_state_new=0 cnt_state_active=0
  local cnt_candidates_age=0 cnt_candidates_idle=0
  local cnt_skip_conntrack=0
  local cnt_deleted_marks=0
  local cnt_dangling_deleted_ul=0 cnt_dangling_deleted_dl=0

  # 1) Clean dangling filters first
  cnt_dangling_deleted_ul="$(gc_dangling_fw_filters "$WAN_DEV" "$UL_ROOT")"
  cnt_dangling_deleted_dl="$(gc_dangling_fw_filters "$IFB_DEV" "$DL_ROOT")"

  load_state

  declare -A present cur_ul cur_dl

  # UL snapshot
  while IFS=$'\t' read -r cid bytes; do
    [[ -n "${cid:-}" ]] || continue
    cnt_ul_lines=$((cnt_ul_lines+1))
    is_kept_classid "$cid" && continue
    h="$(norm_hex4 "${cid#*:}")" || continue
    cur_ul["$h"]="$bytes"
    present["$h"]=1
  done < <(list_classes_bytes "$WAN_DEV" "$UL_ROOT")

  # DL snapshot
  while IFS=$'\t' read -r cid bytes; do
    [[ -n "${cid:-}" ]] || continue
    cnt_dl_lines=$((cnt_dl_lines+1))
    is_kept_classid "$cid" && continue
    h="$(norm_hex4 "${cid#*:}")" || continue
    cur_dl["$h"]="$bytes"
    present["$h"]=1
  done < <(list_classes_bytes "$IFB_DEV" "$DL_ROOT")

  cnt_unique_marks="${#present[@]}"

  # Update state
  for h in "${!present[@]}"; do
    if [[ -z "${first_seen[$h]:-}" ]]; then
      first_seen["$h"]="$now"
      last_seen["$h"]="$now"
      ul_bytes["$h"]="${cur_ul[$h]:-0}"
      dl_bytes["$h"]="${cur_dl[$h]:-0}"
      cnt_state_new=$((cnt_state_new+1))
      continue
    fi

    if [[ "${cur_ul[$h]:-0}" -gt "${ul_bytes[$h]:-0}" || "${cur_dl[$h]:-0}" -gt "${dl_bytes[$h]:-0}" ]]; then
      last_seen["$h"]="$now"
      cnt_state_active=$((cnt_state_active+1))
    fi

    ul_bytes["$h"]="${cur_ul[$h]:-0}"
    dl_bytes["$h"]="${cur_dl[$h]:-0}"
  done

  # Delete by policy
  for h in "${!present[@]}"; do
    local age idle
    age=$((now - first_seen[$h]))
    idle=$((now - last_seen[$h]))

    if [[ "$age" -ge "$QOS_GC_MIN_AGE_SEC" ]]; then
      cnt_candidates_age=$((cnt_candidates_age+1))
    else
      continue
    fi

    if [[ "$idle" -ge "$QOS_GC_IDLE_SEC" ]]; then
      cnt_candidates_idle=$((cnt_candidates_idle+1))
    else
      continue
    fi

    if [[ "$QOS_GC_USE_CONNTRACK" == "1" ]] && conntrack_has_mark "$h"; then
      cnt_skip_conntrack=$((cnt_skip_conntrack+1))
      continue
    fi

    log "GC delete mark=0x$h (idle=${idle}s age=${age}s)"

    delete_filters_for_mark "$WAN_DEV" "$UL_ROOT" "$h"
    delete_filters_for_mark "$IFB_DEV" "$DL_ROOT" "$h"

    delete_class_if_exists "$WAN_DEV" "${UL_ROOT}:$h"
    delete_class_if_exists "$IFB_DEV" "${DL_ROOT}:$h"

    unset first_seen["$h"] last_seen["$h"] ul_bytes["$h"] dl_bytes["$h"]
    cnt_deleted_marks=$((cnt_deleted_marks+1))
  done

  save_state

  # Summary (always)
  log "GC summary: wan_dev=$WAN_DEV ifb_dev=$IFB_DEV ul_root=${UL_ROOT}: dl_root=${DL_ROOT}: dry_run=$QOS_GC_DRY_RUN"
  log "GC summary: ul_classes_lines=$cnt_ul_lines dl_classes_lines=$cnt_dl_lines unique_marks=$cnt_unique_marks state_new=$cnt_state_new state_active=$cnt_state_active"
  log "GC summary: candidates_age>=${QOS_GC_MIN_AGE_SEC}s=$cnt_candidates_age candidates_idle>=${QOS_GC_IDLE_SEC}s=$cnt_candidates_idle skip_conntrack=$cnt_skip_conntrack deleted_marks=$cnt_deleted_marks"
  log "GC summary: dangling_filters_deleted_ul=$cnt_dangling_deleted_ul dangling_filters_deleted_dl=$cnt_dangling_deleted_dl"
}

main "$@"

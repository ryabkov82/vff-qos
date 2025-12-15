#!/usr/bin/env bash
set -euo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin

ENV_FILE="${ENV_FILE:-/etc/vff-qos/qos.env}"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

CONTAINER="${CONTAINER:-remnanode}"
XRAY_LOG="${XRAY_LOG:-/var/log/supervisor/xray.out.log}"

WAN_DEV="${WAN_DEV:-auto}"
IFB_DEV="${IFB_DEV:-ifb0}"

UPLOAD_DEFAULT="${UPLOAD_DEFAULT:-1000mbit}"
DOWNLOAD_DEFAULT="${DOWNLOAD_DEFAULT:-1000mbit}"
VPN_PORT="${VPN_PORT:-443}"

DRY_RUN="${DRY_RUN:-0}"

log(){ echo "[$(date '+%F %T')] $*"; }

detect_wan_if() {
  ip -4 route show default 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

run(){
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "+ $*"
  else
    eval "$@"
  fi
}

# Resolve WAN_DEV=auto
if [[ -z "${WAN_DEV:-}" || "${WAN_DEV}" == "auto" ]]; then
  WAN_DEV="$(detect_wan_if || true)"
fi
if [[ -z "${WAN_DEV:-}" ]]; then
  log "ERROR: cannot determine WAN_DEV (set WAN_DEV=... in $ENV_FILE)"
  exit 1
fi

# Determine server IP (dst of incoming)
SERVER_IP="${SERVER_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')}"
if [[ -z "${SERVER_IP:-}" ]]; then
  log "ERROR: cannot determine SERVER_IP (set SERVER_IP=... manually)"
  exit 1
fi

# Safety: do not proceed until bootstrap has created base qdisc 1:/2:
ensure_bootstrap_ready() {
  tc qdisc show dev "$WAN_DEV" 2>/dev/null | grep -q 'htb 1:' || return 1
  tc qdisc show dev "$IFB_DEV" 2>/dev/null | grep -q 'htb 2:' || return 1
  return 0
}

email_to_mark() {
  local email="$1"
  local c
  c="$(printf '%s' "$email" | cksum | awk '{print $1}')"
  local m=$(( c & 0xffff ))
  # avoid reserved values / special
  if [[ "$m" -eq 0 || "$m" -eq 65534 || "$m" -eq 65535 ]]; then
    m=$(( (m + 1) & 0xffff ))
    [[ "$m" -eq 0 ]] && m=1
  fi
  echo "$m"
}

get_rates_for_email() {
  local _email="$1"
  # пока дефолты; дальше можно подключить таблицу тарифов/override
  echo "$UPLOAD_DEFAULT" "$DOWNLOAD_DEFAULT"
}

class_exists() {
  local dev="$1" classid="$2"
  tc class show dev "$dev" classid "$classid" 2>/dev/null | grep -q .
}

ensure_class_htb() {
  local dev="$1" parent="$2" classid="$3" rate="$4"
  if class_exists "$dev" "$classid"; then
    run "tc class change dev $dev parent $parent classid $classid htb rate $rate ceil $rate"
  else
    run "tc class add dev $dev parent $parent classid $classid htb rate $rate ceil $rate"
  fi
}

# purge any existing fw-filters for this handle (they can accumulate if earlier versions used varying pref)
purge_fw_filters_by_handle() {
  local dev="$1" parent="$2" handle="$3"
  # tc output contains lines like: "filter protocol ip pref 41980 fw ... handle 0x27cd ..."
  tc filter show dev "$dev" parent "$parent" 2>/dev/null \
    | awk -v h="$handle" '$0 ~ /filter protocol ip pref/ {pref=$5} $0 ~ ("handle " h) {print pref}' \
    | while read -r pref; do
        [[ -n "$pref" ]] || continue
        tc filter del dev "$dev" parent "$parent" protocol ip pref "$pref" 2>/dev/null || true
      done
}

ensure_fw_filter() {
  local dev="$1" parent="$2" handle="$3" flowid="$4" pref="$5"
  purge_fw_filters_by_handle "$dev" "$parent" "$handle"
  run "tc filter add dev $dev parent $parent protocol ip pref $pref handle $handle fw flowid $flowid"
}

ensure_tc_for_mark() {
  local mark_dec="$1" ul_rate="$2" dl_rate="$3"

  local hex handle ul_class dl_class pref
  hex="$(printf '%x' "$mark_dec")"
  handle="0x${hex}"
  ul_class="2:${hex}"
  dl_class="1:${hex}"

  # tc pref must be <= 65535; mark_dec is already 1..65533
  pref="$mark_dec"

  log "  [UL] ensure class $ul_class on $IFB_DEV rate=$ul_rate"
  ensure_class_htb "$IFB_DEV" "2:1" "$ul_class" "$ul_rate"
  log "  [UL] ensure fw filter handle=$handle -> $ul_class on $IFB_DEV"
  ensure_fw_filter "$IFB_DEV" "2:" "$handle" "$ul_class" "$pref"

  log "  [DL] ensure class $dl_class on $WAN_DEV rate=$dl_rate"
  ensure_class_htb "$WAN_DEV" "1:1" "$dl_class" "$dl_rate"
  log "  [DL] ensure fw filter handle=$handle -> $dl_class on $WAN_DEV"
  ensure_fw_filter "$WAN_DEV" "1:" "$handle" "$dl_class" "$pref"
}

update_conntrack_mark() {
  local ip="$1" port="$2" mark_dec="$3"

  local cmd
  cmd="conntrack -U -p tcp --orig-src ${ip} --orig-dst ${SERVER_IP} --orig-port-src ${port} --orig-port-dst ${VPN_PORT} --mark ${mark_dec}"

  log "  [CT] $cmd"
  run "$cmd" || true

  if [[ "$DRY_RUN" == "0" ]]; then
    conntrack -L -p tcp 2>/dev/null \
      | grep -F "src=${ip} " \
      | grep -F "sport=${port} " \
      | grep -F "dport=${VPN_PORT} " \
      | head -n 1 \
      | sed 's/^/[CT now] /' || true
  fi
}

log "start: container=$CONTAINER log=$XRAY_LOG WAN_DEV=$WAN_DEV IFB_DEV=$IFB_DEV SERVER_IP=$SERVER_IP VPN_PORT=$VPN_PORT"

# wait until bootstrap is ready (important on boot / restarts)
until ensure_bootstrap_ready; do
  log "bootstrap not ready yet (missing htb 1:/2:). waiting..."
  sleep 2
done

docker exec -i "$CONTAINER" sh -lc "tail -n0 -F '$XRAY_LOG'" \
| while IFS= read -r line; do
    [[ "$line" == *" accepted "* && "$line" == *" email:"* && "$line" == *" from "* ]] || continue

    if [[ "$line" =~ from[[:space:]]([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)[[:space:]].*email:[[:space:]]([^[:space:]]+) ]]; then
      ip="${BASH_REMATCH[1]}"
      port="${BASH_REMATCH[2]}"
      email="${BASH_REMATCH[3]}"

      read -r ul dl < <(get_rates_for_email "$email")
      mark="$(email_to_mark "$email")"

      log "event: email=$email ip=$ip:$port mark=$(printf '0x%x' "$mark") ul=$ul dl=$dl"
      ensure_tc_for_mark "$mark" "$ul" "$dl"
      update_conntrack_mark "$ip" "$port" "$mark"
    fi
  done

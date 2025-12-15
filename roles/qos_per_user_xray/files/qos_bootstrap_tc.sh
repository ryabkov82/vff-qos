#!/usr/bin/env bash
set -euo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin

# ----------------------------
# Load env (works for manual run and for systemd)
# ----------------------------
ENV_FILE="${ENV_FILE:-/etc/vff-qos/qos.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

WAN_DEV="${WAN_DEV:-auto}"
IFB_DEV="${IFB_DEV:-ifb0}"

DEF_CLASS_HEX="${DEF_CLASS_HEX:-fffe}"

# Base shaping (bootstrap)
WAN_CEIL="${WAN_CEIL:-1gbit}"
DEF_UL="${DEF_UL:-${TC_DEFAULT_UL:-1000mbit}}"
DEF_DL="${DEF_DL:-${TC_DEFAULT_DL:-1000mbit}}"

HTB_R2Q="${QOS_HTB_R2Q:-10}"

log(){ echo "[$(date '+%F %T')] $*"; }

detect_wan_if() {
  ip -4 route show default 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

# Resolve WAN_DEV=auto
if [[ -z "${WAN_DEV:-}" || "$WAN_DEV" == "auto" ]]; then
  WAN_DEV="$(detect_wan_if || true)"
fi
if [[ -z "${WAN_DEV:-}" ]]; then
  log "ERROR: cannot determine WAN_DEV (set WAN_DEV=... in $ENV_FILE)"
  exit 1
fi

# ----------------------------
# Ensure IFB exists and is UP
# ----------------------------
modprobe ifb 2>/dev/null || true
if ! ip link show "$IFB_DEV" >/dev/null 2>&1; then
  log "create IFB: $IFB_DEV"
  ip link add "$IFB_DEV" type ifb
fi
ip link set dev "$IFB_DEV" up

# Sanity checks
ip link show "$WAN_DEV" >/dev/null 2>&1 || { log "ERROR: WAN_DEV=$WAN_DEV not found"; exit 1; }
ip link show "$IFB_DEV" >/dev/null 2>&1 || { log "ERROR: IFB_DEV=$IFB_DEV not found"; exit 1; }

log "bootstrap: WAN_DEV=$WAN_DEV IFB_DEV=$IFB_DEV WAN_CEIL=$WAN_CEIL DEF_DL=$DEF_DL DEF_UL=$DEF_UL r2q=$HTB_R2Q"

# ----------------------------
# Ingress redirect (single rule, truly idempotent)
# ----------------------------
# IMPORTANT: replace is not enough; it can leave internal u32 state behind.
tc qdisc del dev "$WAN_DEV" ingress 2>/dev/null || true
tc qdisc add dev "$WAN_DEV" handle ffff: ingress

tc filter add dev "$WAN_DEV" parent ffff: protocol ip pref 10 u32 \
  match u32 0 0 \
  action ctinfo cpmark \
  action mirred egress redirect dev "$IFB_DEV"

# ----------------------------
# HTB base: RECREATE (needed to apply r2q reliably)
# ----------------------------

# WAN egress (download shaping)
tc qdisc del dev "$WAN_DEV" root 2>/dev/null || true
tc qdisc add dev "$WAN_DEV" root handle 1: htb default "${DEF_CLASS_HEX}" r2q "$HTB_R2Q"
tc class add dev "$WAN_DEV" parent 1: classid 1:1 htb rate "$WAN_CEIL" ceil "$WAN_CEIL"
tc class add dev "$WAN_DEV" parent 1:1 classid "1:${DEF_CLASS_HEX}" htb rate "$DEF_DL" ceil "$DEF_DL"

# IFB egress (upload shaping)
tc qdisc del dev "$IFB_DEV" root 2>/dev/null || true
tc qdisc add dev "$IFB_DEV" root handle 2: htb default "${DEF_CLASS_HEX}" r2q "$HTB_R2Q"
tc class add dev "$IFB_DEV" parent 2: classid 2:1 htb rate "$WAN_CEIL" ceil "$WAN_CEIL"
tc class add dev "$IFB_DEV" parent 2:1 classid "2:${DEF_CLASS_HEX}" htb rate "$DEF_UL" ceil "$DEF_UL"

log "done"

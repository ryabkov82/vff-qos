#!/usr/bin/env bash
set -euo pipefail

# Prevent concurrent runs (race condition-safe)
LOCK="/run/vff-qos-nft.lock"
exec 9>"$LOCK"
flock -n 9 || exit 0

NFT="${NFT:-/usr/sbin/nft}"
FAMILY="${QOS_NFT_FAMILY:-inet}"
TABLE="${QOS_NFT_TABLE:-vff_qos_ctmark}"
CHAIN_PRE="${QOS_NFT_CHAIN_PRE:-prerouting}"
CHAIN_OUT="${QOS_NFT_CHAIN_OUT:-output}"

ensure_table_and_chains() {
  # table
  $NFT list table "$FAMILY" "$TABLE" >/dev/null 2>&1 || $NFT add table "$FAMILY" "$TABLE"

  # prerouting chain
  $NFT list chain "$FAMILY" "$TABLE" "$CHAIN_PRE" >/dev/null 2>&1 || \
    $NFT add chain "$FAMILY" "$TABLE" "$CHAIN_PRE" \
      "{ type filter hook prerouting priority mangle; policy accept; }"

  # output chain
  $NFT list chain "$FAMILY" "$TABLE" "$CHAIN_OUT" >/dev/null 2>&1 || \
    $NFT add chain "$FAMILY" "$TABLE" "$CHAIN_OUT" \
      "{ type route hook output priority mangle; policy accept; }"
}

get_rule_handles() {
  # Print handles for rules matching "meta mark set ct mark" in a given chain.
  local chain="$1"
  $NFT -a list chain "$FAMILY" "$TABLE" "$chain" 2>/dev/null \
    | awk 'index($0,"meta mark set ct mark") && match($0,/handle ([0-9]+)/,m){print m[1]}'
}

ensure_single_rule() {
  # Ensure exactly one "meta mark set ct mark" rule exists in the chain.
  local chain="$1"
  mapfile -t handles < <(get_rule_handles "$chain" || true)

  if (( ${#handles[@]} == 0 )); then
    $NFT add rule "$FAMILY" "$TABLE" "$chain" meta mark set ct mark
  elif (( ${#handles[@]} > 1 )); then
    # Keep the first rule, delete the rest (self-heal)
    for h in "${handles[@]:1}"; do
      $NFT delete rule "$FAMILY" "$TABLE" "$chain" handle "$h" || true
    done
  fi
}

ensure_table_and_chains
ensure_single_rule "$CHAIN_PRE"
ensure_single_rule "$CHAIN_OUT"

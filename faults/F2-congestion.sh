#!/usr/bin/env bash
# F2 — Network congestion on the media path (choppy/frozen calls). Applies packet loss +
# jitter with tc netem, but ONLY to outbound UDP media (source ports 50000-60000): traffic
# is fwmark'ed in mangle/POSTROUTING and steered into a netem band of a prio qdisc.
# TCP 443 (signaling, Grafana, the MCP itself) stays clean — everything keeps working,
# calls just degrade. That selectivity is what makes this fault fair on a single node.
#
# Usage: F2-congestion.sh [--revert]     (LOSS/DELAY/JITTER env override the defaults)
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
LOSS="${LOSS:-25%}"; DELAY="${DELAY:-120ms}"; JITTER="${JITTER:-40ms}"
MARK=12

if [ "${1:-}" = "--revert" ]; then
  vmsudo "iptables -t mangle -D POSTROUTING -o eth0 -p udp --sport 50000:60000 -j MARK --set-mark $MARK 2>/dev/null" || true
  vmsudo "tc qdisc del dev eth0 root 2>/dev/null" || true
  log_event F2 revert "netem removed from outbound UDP media"
  exit 0
fi

vmsudo "tc qdisc add dev eth0 root handle 1: prio"
vmsudo "tc qdisc add dev eth0 parent 1:3 handle 30: netem loss $LOSS delay $DELAY $JITTER"
vmsudo "tc filter add dev eth0 parent 1: protocol ip prio 1 handle $MARK fw flowid 1:3"
vmsudo "iptables -t mangle -A POSTROUTING -o eth0 -p udp --sport 50000:60000 -j MARK --set-mark $MARK"

log_event F2 inject "netem loss=$LOSS delay=$DELAY±$JITTER on outbound UDP media (sport 50000-60000) only"
echo "Revert with: $0 --revert"

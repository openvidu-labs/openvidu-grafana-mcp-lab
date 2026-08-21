#!/usr/bin/env bash
# F1 — Block the WebRTC MEDIA transports (simulates a firewall/security-group misconfig).
# Signaling (TCP 443) stays open so participants JOIN, but ICE never connects → no media.
# Blocks: UDP media 50000-60000, TURN/UDP 443, ICE-TCP 7881, WHIP/UDP 7885.
# Rules go on both INPUT (host-networked services) and DOCKER-USER (published ports).
#
# Usage: F1-block-media.sh [--revert]
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
ACTION="-I"; VERB="inject"
[ "${1:-}" = "--revert" ] && ACTION="-D" && VERB="revert"

rule() {
  vmsudo "iptables $ACTION INPUT $* 2>/dev/null" || true
  vmsudo "iptables $ACTION DOCKER-USER $* 2>/dev/null" || true
}
rule -p udp --dport 50000:60000 -j DROP     # WebRTC UDP media
rule -p udp --dport 443         -j DROP     # TURN/UDP
rule -p tcp --dport 7881        -j DROP     # ICE-TCP fallback
rule -p udp --dport 7885        -j DROP     # WHIP/UDP

log_event F1 "$VERB" "media transports blocked on $VM_IP (udp 50000-60000/443/7885, tcp 7881; signaling tcp 443 open)"
[ "$VERB" = inject ] && echo "Revert with: $0 --revert"

#!/usr/bin/env bash
# F9 — Recordings refused: "CPU exhausted". Reproduces the documented OpenVidu recording
# failure (https://openvidu.io/latest/docs/troubleshooting/recording/#cpu-exhausted) WITHOUT
# actually pegging the host: we inject an absurd egress CPU-cost so egress's admission control
# thinks a room-composite recording needs more CPU than the node has, and refuses it.
#
# egress then logs (from the egress container, logs-only — no metrics):
#   "can not accept request"  reason":"cpu"  "error":"not enough CPU"
# Calls are unaffected; only recordings fail. Drive one with: ../load.sh egress-room
#
# Usage: F9-egress-cpu-exhausted.sh [--revert]     (COST env overrides the absurd cost, default 100.0)
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
CFG=/opt/openvidu/data/runtime/config/egress/egress.yaml
BAK="$CFG.faultbak"
COST="${COST:-100.0}"

if [ "${1:-}" = "--revert" ]; then
  vmsudo "sh -c 'if [ -f $BAK ]; then mv -f $BAK $CFG; else sed -i \"s/^    room_composite_cpu_cost: .*/    room_composite_cpu_cost: 2.0/\" $CFG; fi; docker restart egress >/dev/null'"
  log_event F9 revert "egress room_composite_cpu_cost restored; egress restarted"
  exit 0
fi

# Back up the live config, set an impossible cost, reload egress. The 4-space anchor keeps
# the sed from also matching 'audio_room_composite_cpu_cost'.
vmsudo "sh -c 'cp -n $CFG $BAK; sed -i \"s/^    room_composite_cpu_cost: .*/    room_composite_cpu_cost: $COST/\" $CFG; docker restart egress >/dev/null'"
log_event F9 inject "egress room_composite_cpu_cost set to $COST (> node CPUs) — egress refuses recordings with 'not enough CPU'"
echo "Drive a recording to trigger it: ../load.sh egress-room"
echo "Revert with: $0 --revert"

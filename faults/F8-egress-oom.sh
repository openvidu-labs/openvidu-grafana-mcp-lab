#!/usr/bin/env bash
# F8 — Recordings come out broken/half-finished: the egress container is memory-capped and
# the composite recorder (headless Chrome + GStreamer) gets OOM-killed mid-recording.
# Egress emits NO metrics → the only trace is in the logs. This is the fault the original
# study could not run on the playground; with control of the VM's nested docker, we can.
#
# Usage: F8-egress-oom.sh [--revert]      (MEM env overrides the cap, default 512m)
#   Drive a composite recording afterwards: ../load.sh egress-room
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
MEM="${MEM:-512m}"

if [ "${1:-}" = "--revert" ]; then
  # `docker update --memory 0` does NOT clear a limit (Docker quirk), and --memory -1
  # is rejected on current Docker. The reliable way back to the compose default
  # (unlimited) is to force-recreate the container from its compose file.
  vmsudo "sh -c 'cd /opt/openvidu && docker compose up -d --force-recreate --no-deps egress'"
  log_event F8 revert "egress recreated from compose (memory limit removed)"
  exit 0
fi

vmsudo "docker update --memory $MEM --memory-swap $MEM egress"
log_event F8 inject "egress container capped at $MEM memory — composite recorder (Chrome) OOMs mid-recording"
echo "Now start a composite recording under load: ../load.sh egress-room"
echo "Revert with: $0 --revert"

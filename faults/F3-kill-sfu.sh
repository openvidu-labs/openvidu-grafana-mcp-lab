#!/usr/bin/env bash
# F3 — SFU crash. Kills the OpenVidu server container (SIGKILL) mid-load; docker's restart
# policy brings it back, so the symptom is "every call dropped at once, then service came
# back" — the single-node cousin of the media-node-death fault from the Pro study.
#
# Usage: F3-kill-sfu.sh          (no revert needed — it restarts on its own; the script
#                                 verifies that, and restarts it manually as a fallback)
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
SFU="${SFU:-openvidu}"

vmsudo "docker kill $SFU"
log_event F3 inject "SFU container '$SFU' killed (SIGKILL) — all rooms dropped"

echo ">>> waiting for the restart policy to bring it back ..."
for i in $(seq 1 30); do
  st="$(vmsudo "docker inspect -f '{{.State.Running}}' $SFU 2>/dev/null" || echo false)"
  [ "$st" = "true" ] && { log_event F3 note "SFU restarted automatically after ~$((i*3))s"; exit 0; }
  sleep 3
done
echo ">>> no auto-restart — starting it manually"
vmsudo "docker start $SFU"
log_event F3 note "SFU restarted manually (no restart policy)"

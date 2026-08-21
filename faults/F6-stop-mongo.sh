#!/usr/bin/env bash
# F6 — MongoDB down. Media keeps flowing (rooms/WebRTC don't need mongo), but everything
# stateful — OpenVidu Meet rooms/config, the dashboard, analytics — starts failing.
# Quiet-ish: calls look perfectly healthy.
#
# Usage: F6-stop-mongo.sh [--revert]
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
if [ "${1:-}" = "--revert" ]; then
  vmsudo "docker start mongo"
  log_event F6 revert "mongo started again"
  exit 0
fi
vmsudo "docker stop mongo"
log_event F6 inject "mongo stopped — stateful operations (Meet/dashboard/analytics) fail; calls unaffected"
echo "Revert with: $0 --revert"

#!/usr/bin/env bash
# F5 — Redis down: the coordination plane dies. No new rooms/recordings; everything logs
# "connection refused" against the redis port. The "confusable fault" from the study.
#
# Usage: F5-stop-redis.sh [--revert]
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
if [ "${1:-}" = "--revert" ]; then
  vmsudo "docker start redis"
  log_event F5 revert "redis started again"
  exit 0
fi
vmsudo "docker stop redis"
log_event F5 inject "redis stopped — coordination plane down (no new rooms/egress)"
echo "Revert with: $0 --revert"

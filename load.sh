#!/usr/bin/env bash
# Put live traffic on the lab so the Grafana panels have samples. Uses the LiveKit
# CLI in Docker (no host install) on the lab network, so it reaches the SFU.
#
# Usage:
#   ./load.sh baseline                 # 3 publishers + 3 subscribers, 10 min
#   ./load.sh heavy                    # 8 publishers + 8 subscribers, 10 min
#   ./load.sh egress-room              # room with auto composite recording + load
#   ./load.sh custom -- -p 5 -s 5 ...  # raw lk load-test args after `--`
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

[ -n "${LK_SECRET:-}" ] || { echo "ERROR: run ./up.sh first (LK_SECRET not set)" >&2; exit 1; }
URL="wss://$DOMAIN"
MODE="${1:-baseline}"; shift || true

case "$MODE" in
  baseline)
    lk_docker -- load-test --url "$URL" --api-key "$LK_KEY" --api-secret "$LK_SECRET" \
      --room repro-load --video-publishers 3 --subscribers 3 --duration 10m --video-resolution high ;;
  heavy)
    lk_docker -- load-test --url "$URL" --api-key "$LK_KEY" --api-secret "$LK_SECRET" \
      --room repro-load --video-publishers 8 --subscribers 8 --duration 10m --video-resolution high ;;
  egress-room)
    # Room with an automatic room-composite recording, then load in it. The egress
    # writes to the deployment's default storage (MinIO) — that's the fault surface.
    CFG="$(mktemp)"; trap 'rm -f "$CFG"' EXIT
    printf '%s\n' '{ "file_outputs": [ { "file_type": "MP4", "filepath": "{room_name}/room_{time}.mp4" } ], "layout": "grid" }' > "$CFG"
    lk_docker -v "$CFG:/egress.json:ro" -- room create --url "$URL" --api-key "$LK_KEY" --api-secret "$LK_SECRET" \
      --room-egress-file /egress.json repro-rec || true
    lk_docker -- load-test --url "$URL" --api-key "$LK_KEY" --api-secret "$LK_SECRET" \
      --room repro-rec --video-publishers 2 --subscribers 1 --duration 5m --video-resolution high ;;
  custom)
    [ "${1:-}" = "--" ] && shift
    lk_docker -- load-test --url "$URL" --api-key "$LK_KEY" --api-secret "$LK_SECRET" --room repro-load "$@" ;;
  *)
    echo "usage: $0 baseline|heavy|egress-room|custom [-- lk load-test args]" >&2; exit 2 ;;
esac

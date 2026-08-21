#!/usr/bin/env bash
# F7 — RTMP ingest won't come through. Simulates a misconfigured streamer (wrong stream
# key): an ffmpeg loop keeps publishing to the ingress with a BAD key, which the ingress
# rejects with "ingress does not exist". Room stays empty. Ingress emits NO metrics →
# the signal is Loki logs only.
#
# ffmpeg runs in Docker (on the lab network, so it reaches the ingress) — no host install.
#
# Usage: F7-ingress-badkey.sh [--revert]
#   KEY env overrides the (bad) stream key; URL overrides the RTMP base.
source "$(cd "$(dirname "$0")/.." && pwd)/env.sh"
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
CNAME=repro-f7-ffmpeg
URL="${URL:-rtmps://$DOMAIN:1935/rtmp}"
KEY="${KEY:-BADKEY123}"

if [ "${1:-}" = "--revert" ]; then
  docker rm -f "$CNAME" >/dev/null 2>&1 || true
  log_event F7 revert "stopped bad-key ffmpeg container"
  exit 0
fi

docker rm -f "$CNAME" >/dev/null 2>&1 || true
# Detached + restart: ffmpeg exits when the ingress rejects the key, docker restarts it —
# a streamer that keeps retrying with the wrong key.
docker run -d --name "$CNAME" --network "$NETWORK" --restart unless-stopped \
  "$FFMPEG_IMAGE" \
  -hide_banner -loglevel error -re \
  -f lavfi -i "testsrc2=size=640x480:rate=30" -f lavfi -i "sine=frequency=440" \
  -c:v libx264 -preset veryfast -tune zerolatency -b:v 1000k -pix_fmt yuv420p -c:a aac \
  -f flv "$URL/$KEY" >/dev/null

log_event F7 inject "ffmpeg container publishing to $URL with BAD key '$KEY' (ingress rejects: 'ingress does not exist'; room stays empty)"
echo "Revert with: $0 --revert"

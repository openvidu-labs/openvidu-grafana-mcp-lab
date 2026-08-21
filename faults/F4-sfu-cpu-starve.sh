#!/usr/bin/env bash
# F4 — SFU CPU starvation (undersized/overloaded server). Caps the CPU available to the
# openvidu (SFU) container with a cgroup limit; under real load the SFU can't keep up:
# packet loss climbs, quality score collapses, RTT/jitter rise — while the network is fine.
# The interesting blind question: can the model tell CPU saturation from network congestion?
#
# Usage: F4-sfu-cpu-starve.sh [--vm] [--revert]
#   default: cap ONLY the SFU container (CPUS env, default 0.4) — Grafana stays healthy.
#   --vm:    cap the WHOLE fake VM (VM_CPUS env, default 2) and burn cores inside it —
#            the literal "the machine is too small" scenario. Realistic, but note the
#            observability stack degrades too (it lives on the same box).
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
CPUS="${CPUS:-0.4}"; VM_CPUS="${VM_CPUS:-2}"
VM_NAME="fake-vm-${VM_IP//./-}"
BURN_PIDFILE=/tmp/repro-f4-burn.pids

MODE="sfu"; REVERT=""
for a in "$@"; do case "$a" in --vm) MODE=vm ;; --revert) REVERT=1 ;; esac; done

if [ "$MODE" = "sfu" ]; then
  if [ -n "$REVERT" ]; then
    vmsudo "docker update --cpus 0 openvidu"
    log_event F4 revert "SFU CPU limit removed"
  else
    vmsudo "docker update --cpus $CPUS openvidu"
    log_event F4 inject "SFU container capped at $CPUS CPUs (cgroup) — starves under load; network untouched"
    echo "Drive load now (e.g. ../load.sh heavy). Revert with: $0 --revert"
  fi
else
  if [ -n "$REVERT" ]; then
    vmssh "[ -f $BURN_PIDFILE ] && xargs -r kill < $BURN_PIDFILE; rm -f $BURN_PIDFILE" || true
    docker update --cpus 0 "$VM_NAME"
    log_event F4 revert "VM CPU limit removed; burners killed"
  else
    docker update --cpus "$VM_CPUS" "$VM_NAME"
    # Burn most of the capped capacity from inside the VM (a "noisy neighbor" process).
    vmssh ": > $BURN_PIDFILE; for i in 1 2 3 4; do nohup sh -c 'while :; do :; done' >/dev/null 2>&1 & echo \$! >> $BURN_PIDFILE; done"
    log_event F4 inject "whole VM capped at $VM_CPUS CPUs + 4 busy-loop burners inside (undersized instance)"
    echo "Revert with: $0 --vm --revert"
  fi
fi

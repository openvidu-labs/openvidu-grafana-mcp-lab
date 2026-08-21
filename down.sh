#!/usr/bin/env bash
# Tear the lab down: revert any active fault, stop load, remove the fake VM
# (container + volumes + SSH credentials). Keeps .state/lab.env so a later ./up.sh
# reuses the same secrets. Pass --purge to also wipe .state and the fake-vm clone.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

# Best-effort: revert whatever scenario.sh left active.
[ -x "$LAB_DIR/scenario.sh" ] && "$LAB_DIR/scenario.sh" stop >/dev/null 2>&1 || true

if [ -d "$FAKE_VM_DIR" ]; then
  "$FAKE_VM_DIR/fake-vm.sh" stop "$VM_IP" || true
fi

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$STATE_DIR" "$FAKE_VM_DIR"
  echo ">>> purged .state and the fake-vm clone"
fi
echo ">>> lab down."

# Shared helpers for the fault scripts. Source me; don't run me.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/env.sh"

FAULT_LOG="$LAB_DIR/faults/fault-log.md"

# log_event <id> <inject|revert> <description> — the ground-truth ledger every
# injection writes to (timestamps seed the blind sessions' incident windows).
log_event() {
  local id="$1" verb="$2" desc="$3"
  printf -- "- **%s** \`%s\` %s — %s\n" "$id" "$(date '+%Y-%m-%d %H:%M:%S')" "$verb" "$desc" >> "$FAULT_LOG"
  echo "[$id $verb] $desc"
}

# vmsudo <cmd...> — run a root command inside the lab VM.
vmsudo() { vmssh "sudo $*"; }

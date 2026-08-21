#!/usr/bin/env bash
# One command per scenario: bring the lab to a broken-in-the-right-way state so YOU can
# point Claude at it and check what it finds.
#
#   ./scenario.sh list            # what can I break?
#   ./scenario.sh F4              # lab up (if needed) + load + inject F4 + print the operator prompt
#   ./scenario.sh status          # what's active right now
#   ./scenario.sh stop            # revert the active fault + stop the load
#
# Integrity rule (same as the study): ONE fault at a time. `stop` before switching.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"
cd "$LAB_DIR"

STATE="$LAB_DIR/.state"; mkdir -p "$STATE"
ACTIVE_F="$STATE/active-scenario"
LOAD_PIDF="$STATE/load.pid"

SCENARIOS="F1 F2 F3 F4 F5 F6 F7 F8 F9 N1"

# scenario → load profile (baseline | heavy | egress-room | none)
load_profile() {
  case "$1" in
    F8|F9) echo egress-room ;;
    F4)    echo heavy ;;
    *)     echo baseline ;;
  esac
}

# scenario → injection command (relative to the repo root)
inject() {
  case "$1" in
    F1) faults/F1-block-media.sh ;;
    F2) faults/F2-congestion.sh ;;
    F3) faults/F3-kill-sfu.sh ;;
    F4) faults/F4-sfu-cpu-starve.sh ;;
    F5) faults/F5-stop-redis.sh ;;
    F6) faults/F6-stop-mongo.sh ;;
    F7) faults/F7-ingress-badkey.sh ;;
    F8) faults/F8-egress-oom.sh ;;
    F9) faults/F9-egress-cpu-exhausted.sh ;;
    N1) echo "(negative control — nothing to inject)" ;;
  esac
}

revert() {
  case "$1" in
    F1) faults/F1-block-media.sh --revert ;;
    F2) faults/F2-congestion.sh --revert ;;
    F4) faults/F4-sfu-cpu-starve.sh --revert ;;
    F5) faults/F5-stop-redis.sh --revert ;;
    F6) faults/F6-stop-mongo.sh --revert ;;
    F7) faults/F7-ingress-badkey.sh --revert ;;
    F8) faults/F8-egress-oom.sh --revert ;;
    F9) faults/F9-egress-cpu-exhausted.sh --revert ;;
    F3|N1) : ;;   # nothing persistent to revert
  esac
}

start_load() {
  local profile="$1"
  [ "$profile" = none ] && return 0
  command -v docker >/dev/null || { echo "WARNING: docker not found — no load will be generated"; return 0; }
  # Supervisor loop in its own process group: lk load-test ends after --duration, so
  # restart it until `stop`. Killed as a group, by exact PID — never by name.
  setsid bash -c "while :; do \"$LAB_DIR/load.sh\" $profile >/dev/null 2>&1; sleep 2; done" &
  echo $! > "$LOAD_PIDF"
  echo ">>> load profile '$profile' running (supervisor pid $(cat "$LOAD_PIDF"))"
}

stop_load() {
  if [ -f "$LOAD_PIDF" ]; then
    kill -- -"$(cat "$LOAD_PIDF")" 2>/dev/null || true
    rm -f "$LOAD_PIDF"
    echo ">>> load stopped"
  fi
}

print_prompt() {
  local sid="$1" window="$2"
  python3 - "$LAB_DIR/prompts/scenarios.yaml" "$sid" "$window" "$GRAFANA_URL/" <<'PY'
import sys,yaml
scn,sid,win,url=sys.argv[1:5]
s=next(x for x in yaml.safe_load(open(scn))["scenarios"] if x["id"]==sid)
print(s["prompt"].replace("{{WINDOW}}",win).replace("{{GRAFANA_URL}}",url).strip())
PY
}

lab_up() {
  curl -skf "$GRAFANA_URL/api/health" >/dev/null 2>&1 && return 0
  echo ">>> lab is not up — running ./up.sh first"
  "$LAB_DIR/up.sh"
}

CMD="${1:-}"
case "$CMD" in
  list)
    python3 - "$LAB_DIR/prompts/scenarios.yaml" <<'PY'
import sys,yaml
for s in yaml.safe_load(open(sys.argv[1]))["scenarios"]:
    print(f"  {s['id']:<4} {s['title']}")
PY
    ;;

  status)
    if [ -f "$ACTIVE_F" ]; then echo "active scenario: $(cat "$ACTIVE_F")"; else echo "no active scenario"; fi
    [ -f "$LOAD_PIDF" ] && echo "load supervisor pid: $(cat "$LOAD_PIDF")"
    tail -3 "$LAB_DIR/faults/fault-log.md" 2>/dev/null || true
    ;;

  stop)
    [ -f "$ACTIVE_F" ] || { echo "no active scenario"; stop_load; exit 0; }
    SID="$(cat "$ACTIVE_F")"
    echo ">>> reverting $SID"
    revert "$SID"
    stop_load
    rm -f "$ACTIVE_F"
    echo ">>> clean."
    ;;

  F1|F2|F3|F4|F5|F6|F7|F8|F9|N1)
    SID="$CMD"
    if [ -f "$ACTIVE_F" ]; then
      echo "ERROR: scenario $(cat "$ACTIVE_F") is already active — run './scenario.sh stop' first" >&2
      exit 1
    fi
    lab_up
    PROFILE="$(load_profile "$SID")"

    if [ "$SID" = F4 ] || [ "$SID" = F8 ] || [ "$SID" = F9 ]; then
      # Resource caps / admission limits must be in place BEFORE the load (and the
      # recording attempts) arrive, so the fault is what the metrics/logs capture.
      inject "$SID"
      start_load "$PROFILE"
      echo ">>> letting the load run into the fault (60s) ..."; sleep 60
    elif [ "$SID" = N1 ]; then
      start_load "$PROFILE"
      echo ">>> healthy load warming up (60s) ..."; sleep 60
    else
      # Establish a healthy baseline first, then break it (that's the story the
      # metrics should tell: it worked, then it didn't).
      start_load "$PROFILE"
      echo ">>> healthy baseline (45s) ..."; sleep 45
      inject "$SID"
    fi

    WINDOW="$(date +%H:%M) today"
    echo "$SID" > "$ACTIVE_F"

    cat <<EOF

=========================================================================
Scenario $SID is LIVE. Now let Claude find it.

Interactive (what a reader does):
    cd $LAB_DIR/mcp/control        # bare Grafana MCP
    # or: cd $LAB_DIR/mcp/with-skill   (MCP + the triage skill)
    claude

  ...and paste the operator's complaint:
-------------------------------------------------------------------------
$(print_prompt "$SID" "$WINDOW")
-------------------------------------------------------------------------

Headless (the study's harness, both arms):
    runner/run-both-arms.sh $SID 1 "$WINDOW"

The answer key is in prompts/scenarios.yaml (no peeking before the verdict!).
When you're done:   ./scenario.sh stop
=========================================================================
EOF
    ;;

  *)
    echo "usage: $0 list | status | stop | <scenario-id>"; echo; echo "scenarios:"; "$0" list ;;
esac

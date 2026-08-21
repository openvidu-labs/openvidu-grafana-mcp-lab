#!/usr/bin/env bash
# Run control + treatment blind sessions CONCURRENTLY for one scenario/window.
# They only read the (persisted) incident window in Grafana, so running them together is safe.
# Usage: run-both-arms.sh <scenario_id> <rep> "<WINDOW>"
set -euo pipefail
SID="${1:?scenario}"; REP="${2:?rep}"; WINDOW="${3:?window}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCR="$ROOT/transcripts"; mkdir -p "$SCR"

echo ">> launching control + treatment for $SID rep$REP (window: $WINDOW)"
bash "$ROOT/runner/run-session.sh" "$SID" control   "$REP" "$WINDOW" >"$SCR/${SID}_control_rep${REP}.run.log" 2>&1 &
P1=$!
bash "$ROOT/runner/run-session.sh" "$SID" treatment "$REP" "$WINDOW" >"$SCR/${SID}_treatment_rep${REP}.run.log" 2>&1 &
P2=$!
wait $P1; wait $P2
echo ">> both arms done."
for arm in control treatment; do
  echo "=================== $SID $arm rep$REP — VERDICT ==================="
  cat "$SCR/${SID}_${arm}_rep${REP}.verdict.txt" 2>/dev/null || echo "(missing)"
  echo
done

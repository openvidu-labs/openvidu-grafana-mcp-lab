#!/usr/bin/env bash
# Run ONE blind debugging session: a headless Claude Code with ONLY the read-only Grafana MCP.
#
# Usage:
#   run-session.sh <scenario_id> <arm: control|treatment> <rep> "<WINDOW>" [GRAFANA_URL]
# Example:
#   run-session.sh F1 control 1 "14:30 today"
#
# Blind guarantees:
#   --strict-mcp-config  → ignores every other configured MCP
#   allowedTools         → only the grafana MCP (+ Skill for treatment). NO Bash, NO Read, NO repo.
#   The session never sees this repo, the source, the fault, or the answer key.
set -euo pipefail

SID="${1:?scenario id}"; ARM="${2:?control|treatment}"; REP="${3:?rep}"
WINDOW="${4:?time window}"; GURL="${5:-https://playground.openvidu-local.dev/grafana/}"
# MODEL defaults to whatever your Claude Code is configured to use. A strong model is
# recommended for this task; override with e.g. MODEL=opus.
MODEL="${MODEL:-}"; MAXTURNS="${MAXTURNS:-40}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCN="$ROOT/prompts/scenarios.yaml"
OUTDIR="$ROOT/transcripts"; mkdir -p "$OUTDIR"
STAMP="${SID}_${ARM}_rep${REP}"
JSONL="$OUTDIR/$STAMP.jsonl"; META="$OUTDIR/$STAMP.meta.json"

# Pull the operator prompt for this scenario and fill placeholders.
PROMPT="$(python3 - "$SCN" "$SID" "$WINDOW" "$GURL" <<'PY'
import sys,yaml
scn,sid,win,url=sys.argv[1:5]
d=yaml.safe_load(open(scn))
s=next(x for x in d["scenarios"] if x["id"]==sid)
print(s["prompt"].replace("{{WINDOW}}",win).replace("{{GRAFANA_URL}}",url).strip())
PY
)"

if [ "$ARM" = "treatment" ]; then
  WORKDIR="$ROOT/mcp/with-skill"
  ALLOWED="mcp__grafana Skill"
else
  WORKDIR="$ROOT/mcp/control"
  ALLOWED="mcp__grafana"
fi
MCPCFG="$WORKDIR/.mcp.json"

SYS_APPEND="You are an on-call site-reliability engineer. An operator has reported a problem and given you access to their Grafana. Investigate using ONLY the Grafana tools available to you (dashboards, Prometheus metrics, Loki logs). You have no shell, no source code, and no other access. Reason from the observability data. State a concrete root-cause hypothesis and a remediation, or say clearly if the data shows no server-side fault. Do not invent metric names or nodes you have not observed."

echo ">> $STAMP  model=$MODEL  arm=$ARM  workdir=$WORKDIR"
echo ">> prompt: $PROMPT"

python3 - "$META" "$SID" "$ARM" "$REP" "$MODEL" "$WINDOW" "$GURL" "$PROMPT" <<'PY'
import sys,json,datetime
f,sid,arm,rep,model,win,url,prompt=sys.argv[1:9]
json.dump({"scenario":sid,"arm":arm,"rep":rep,"model":model,"window":win,
          "grafana_url":url,"prompt":prompt,
          "started":datetime.datetime.now().isoformat(timespec="seconds")},open(f,"w"),indent=2)
PY

cd "$WORKDIR"
MODEL_ARG=(); [ -n "$MODEL" ] && MODEL_ARG=(--model "$MODEL")
set +e
claude -p "$PROMPT" \
  "${MODEL_ARG[@]}" \
  --strict-mcp-config --mcp-config "$MCPCFG" \
  --allowedTools $ALLOWED \
  --disallowedTools "Bash" "Read" "Edit" "Write" "WebFetch" "WebSearch" \
  --append-system-prompt "$SYS_APPEND" \
  --max-turns "$MAXTURNS" \
  --permission-mode bypassPermissions \
  --output-format stream-json --verbose \
  > "$JSONL" 2>"$OUTDIR/$STAMP.stderr"
RC=$?
set -e
echo ">> exit=$RC  transcript=$JSONL ($(wc -l < "$JSONL") lines)"

# Extract the final assistant text as the session's verdict (for grading).
python3 - "$JSONL" "$OUTDIR/$STAMP.verdict.txt" <<'PY'
import sys,json
jl,out=sys.argv[1],sys.argv[2]
final=""
for line in open(jl):
    line=line.strip()
    if not line: continue
    try: ev=json.loads(line)
    except: continue
    if ev.get("type")=="assistant":
        for b in ev.get("message",{}).get("content",[]):
            if b.get("type")=="text": final=b["text"]
    if ev.get("type")=="result" and ev.get("result"): final=ev["result"]
open(out,"w").write(final or "(no final text)")
print("verdict written:",out)
PY

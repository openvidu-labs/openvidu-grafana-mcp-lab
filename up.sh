#!/usr/bin/env bash
# Bring up the whole lab on ANY Linux machine with Docker — no other host tooling,
# no credentials committed, nothing that depends on the author's setup:
#   1. a fake VM (OpenVidu/openvidu-fake-vm) at 10.5.0.3, cloned inside this repo
#   2. OpenVidu Single Node COMMUNITY (no license) installed inside it, with the
#      observability module (Grafana + Mimir + Loki) and a real trusted TLS cert
#      for playground.openvidu-local.dev
#   3. random lab secrets generated into .state/ (git-ignored) and a read-only
#      Grafana token wired into .state/mcp.env for the dockerised Grafana MCP
#
# Usage: ./up.sh          (first full run takes ~10-20 min: image pulls inside the VM)
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

command -v docker >/dev/null || { echo "ERROR: docker is required" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: the docker daemon is not reachable" >&2; exit 1; }
mkdir -p "$STATE_DIR"

# --- 0. generate lab secrets once (git-ignored) --------------------------------
gen_secret() { head -c 48 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 40; }
if [ ! -f "$STATE_DIR/lab.env" ] || ! grep -q '^LK_SECRET=' "$STATE_DIR/lab.env" 2>/dev/null; then
  echo ">>> generating lab secrets into .state/lab.env (never committed)"
  {
    echo "LK_SECRET=$(gen_secret)"
    echo "GRAFANA_PASS=$(gen_secret)"
  } > "$STATE_DIR/lab.env"
fi
# shellcheck disable=SC1091
. "$STATE_DIR/lab.env"

# --- 1. the fake VM (cloned inside the repo) -----------------------------------
if [ ! -d "$FAKE_VM_DIR" ]; then
  echo ">>> cloning OpenVidu/openvidu-fake-vm @ $FAKE_VM_REF into $FAKE_VM_DIR"
  FVURL=https://github.com/OpenVidu/openvidu-fake-vm
  # Fast path: shallow-clone the pinned tag/branch. Fall back to a full clone +
  # checkout if FAKE_VM_REF is a raw commit SHA (which --branch can't take).
  if ! git clone --quiet --depth 1 --branch "$FAKE_VM_REF" "$FVURL" "$FAKE_VM_DIR" 2>/dev/null; then
    git clone --quiet "$FVURL" "$FAKE_VM_DIR"
    git -C "$FAKE_VM_DIR" checkout --quiet "$FAKE_VM_REF" \
      || { echo "ERROR: could not check out pinned fake-vm ref $FAKE_VM_REF" >&2; exit 1; }
  fi
fi
if docker inspect "fake-vm-${VM_IP//./-}" >/dev/null 2>&1; then
  echo ">>> fake-vm $VM_IP already exists — reusing it"
else
  "$FAKE_VM_DIR/fake-vm.sh" start "$VM_IP"
fi

# --- 2. OpenVidu Single Node Community inside the VM ---------------------------
if vmssh "test -f /opt/openvidu/config/openvidu.env" 2>/dev/null; then
  echo ">>> OpenVidu already installed in the VM — making sure it's started"
  vmssh "sudo systemctl start openvidu" || true
else
  echo ">>> installing OpenVidu Single Node Community $OV_VERSION (pulls all images inside the VM)"
  B64_CERT="$(base64 -w0 "$FAKE_VM_DIR/fullchain.pem")"
  B64_KEY="$(base64 -w0 "$FAKE_VM_DIR/privkey.pem")"
  vmssh "curl -fsSL http://get.openvidu.io/community/singlenode/${OV_VERSION}/install.sh -o /tmp/ov-install.sh"
  vmssh "sudo sh /tmp/ov-install.sh --no-tty \
    --domain-name=$DOMAIN \
    --certificate-type=owncert \
    --owncert-public-key=$B64_CERT \
    --owncert-private-key=$B64_KEY \
    --enabled-modules=observability,openviduMeet \
    --livekit-api-key=$LK_KEY \
    --livekit-api-secret=$LK_SECRET \
    --grafana-admin-user=$GRAFANA_ADMIN \
    --grafana-admin-password=$GRAFANA_PASS \
    --private-ip=$VM_IP \
    --start-after-install"
fi

# --- 3. wait for Grafana -------------------------------------------------------
echo ">>> waiting for https://$DOMAIN (Grafana health) ..."
for i in $(seq 1 90); do
  if curl -skf "$GRAFANA_URL/api/health" >/dev/null 2>&1; then echo ">>> Grafana is up"; break; fi
  [ "$i" = 90 ] && { echo "ERROR: Grafana did not come up in time" >&2; exit 1; }
  sleep 5
done

# --- 4. read-only Viewer token → .state/mcp.env (consumed by the dockerised MCP)
SA_NAME="mcp-readonly"
SA_ID=$(curl -skf -u "$GRAFANA_ADMIN:$GRAFANA_PASS" "$GRAFANA_URL/api/serviceaccounts/search?query=$SA_NAME" \
  | python3 -c 'import sys,json; r=json.load(sys.stdin); a=[x for x in r.get("serviceAccounts",[]) if x["name"]=="'"$SA_NAME"'"]; print(a[0]["id"] if a else "")')
if [ -z "$SA_ID" ]; then
  SA_ID=$(curl -skf -u "$GRAFANA_ADMIN:$GRAFANA_PASS" -H 'Content-Type: application/json' \
    -d '{"name":"'"$SA_NAME"'","role":"Viewer","isDisabled":false}' \
    "$GRAFANA_URL/api/serviceaccounts" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
fi
TOKEN=$(curl -skf -u "$GRAFANA_ADMIN:$GRAFANA_PASS" -H 'Content-Type: application/json' \
  -d '{"name":"mcp-'"$(date +%s)"'"}' "$GRAFANA_URL/api/serviceaccounts/$SA_ID/tokens" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["key"])')
[ -n "$TOKEN" ] || { echo "ERROR: could not mint the read-only Grafana token" >&2; exit 1; }

# The Grafana MCP container reads this file (docker --env-file). Read-only token only.
cat > "$STATE_DIR/mcp.env" <<EOF
GRAFANA_URL=$GRAFANA_URL/
GRAFANA_SERVICE_ACCOUNT_TOKEN=$TOKEN
EOF
chmod 600 "$STATE_DIR/mcp.env"

# Pre-pull the pinned tooling images so the first scenario/MCP call isn't slow.
echo ">>> pre-pulling pinned tooling images (mcp-grafana, livekit-cli, ffmpeg) ..."
docker pull "$MCP_IMAGE"    >/dev/null 2>&1 || echo "   (warning: could not pull $MCP_IMAGE)"
docker pull "$LK_IMAGE"     >/dev/null 2>&1 || echo "   (warning: could not pull $LK_IMAGE)"
docker pull "$FFMPEG_IMAGE" >/dev/null 2>&1 || echo "   (warning: could not pull $FFMPEG_IMAGE)"

cat <<EOF

Lab is up.

  App / API:  https://$DOMAIN            (LiveKit API key: $LK_KEY)
  Grafana:    $GRAFANA_URL/              (admin: $GRAFANA_ADMIN — password in .state/lab.env)
  VM:         ssh fake-vm-${VM_IP//./-}  (ubuntu, passwordless sudo)
  MCP:        dockerised grafana/mcp-grafana, read-only (token in .state/mcp.env)

Prerequisite for the debugging sessions: Claude Code (https://claude.com/claude-code).
Everything else runs in Docker — no local binaries needed.

Next:
  ./scenario.sh list                 # see the faults you can inject
  ./scenario.sh F1                   # break it the right way + print the operator prompt
EOF

# OpenVidu and Grafana MCP debugging lab

This repo stands up a local OpenVidu Single Node deployment wired to a read-only Grafana MCP, with a few realistic faults you can inject to practice debugging OpenVidu using only what Grafana shows. It is the reproducible companion to an openvidu.io blog post — link coming soon. <!-- TODO: add blog URL once published -->

The lab runs on a Linux host with Docker.

It stands up a real OpenVidu deployment with its full
observability stack, breaks it in realistic ways one command at a time, and hands the
symptom to a blind Claude Code session that may only look
through the Grafana MCP.

## How it works

- A simulated VM ([OpenVidu/openvidu-fake-vm](https://github.com/OpenVidu/openvidu-fake-vm))
  comes up at the fixed IP `10.5.0.3`. The public wildcard `playground.openvidu-local.dev`
  resolves *exactly there*, and the VM auto-downloads a **real, publicly-trusted** wildcard
  TLS certificate — so the deployment gets an honest domain and HTTPS with no `/etc/hosts`
  edits and no self-signed warnings.
- Inside it we install **OpenVidu Single Node Community** (the free edition) with the
  `observability` module: **Grafana + Mimir + Loki**, the same stack the blog studies.
- Faults are injected into that live cluster; a blind Claude Code session with only the
  read-only **Grafana MCP** (run in Docker) tries to find each root cause — with and without
  a purpose-built triage skill.

## Requirements

- **Linux host with Docker.** That's the one hard requirement — the design needs the Docker
  bridge reachable from the host by IP, which is a Linux property. (~4 CPUs / 8 GB RAM /
  ~15 GB disk free; the images are pulled inside the VM.)
- **[Claude Code](https://claude.com/claude-code)** for the debugging sessions.
- `python3`, `git`, `curl` (present on essentially every Linux box).

Everything else — the Grafana MCP server, the LiveKit load generator, ffmpeg — runs in
Docker. There are **no local binaries to install** and **no credentials in this repo**:
`up.sh` generates the lab secrets at first run into `.state/` (git-ignored) and mints a
read-only Grafana token for the MCP.

## Quick start

```bash
git clone https://github.com/openvidu-labs/openvidu-grafana-mcp-lab
cd openvidu-grafana-mcp-lab
./up.sh                # VM + OpenVidu Community + read-only token (first run ~15 min)
```

Then pick a fault. One command brings the cluster to a broken-the-right-way state — a
healthy baseline first, *then* the fault, so the metrics tell the honest story — and prints
the operator's complaint, ready to paste:

```bash
./scenario.sh list     # the menu
./scenario.sh F1       # inject + live load + the prompt to hand Claude
```

Now play the on-call engineer. Point Claude Code at the read-only Grafana and give it
the line the script printed:

```bash
cd mcp/control         # bare Grafana MCP   (or: cd mcp/with-skill  for the skill arm)
claude
```

> The lab is designed to be used with Claude Code, but you can use any agent that can access Grafana MCP (see the `.mcp.json` files for the read-only token and the skill at `mcp/with-skill` in case you want to use a different agent).

Watch it investigate. Compare the two arms. The answer key is in `prompts/scenarios.yaml` —
peek *after* you've formed your own verdict. When you're done, or to switch faults (one at a
time — that's the rule):

```bash
./scenario.sh stop
```

Prefer it fully automated? The study's headless harness runs both arms and prints their
verdicts:

```bash
runner/run-both-arms.sh F1 1 "$(date +%H:%M) today"
```

## The faults

| Command | Scenario | Signal character |
|---|---|---|
| `./scenario.sh F1` | firewall eats the WebRTC media ports; joins work, no media | loud (metrics + logs) |
| `./scenario.sh F2` | packet loss + jitter on outbound media (tc netem) | loud (metric) |
| `./scenario.sh F3` | SFU SIGKILLed mid-load, auto-restarts | logs + metric reset |
| `./scenario.sh F4` | SFU CPU-capped; chokes under load (looks like congestion — is it?) | resource, confusable |
| `./scenario.sh F5` | Redis down (coordination plane) | loud but confusable |
| `./scenario.sh F6` | Mongo down; stateful ops fail, calls fine | quiet-ish, logs |
| `./scenario.sh F7` | streamer publishes RTMP with a wrong key | logs-only, explicit |
| `./scenario.sh F8` | egress memory-capped; composite recorder OOMs mid-recording | logs-only |
| `./scenario.sh F9` | egress refuses recordings — "CPU exhausted" (config-induced) | logs-only, explicit |
| `./scenario.sh N1` | healthy cluster (negative control) | nothing wrong |

The blog post walks through five of these: `F1`, `F2`, `F5`, `F7`, and `F9`. Every injection logs
ground truth (timestamp + cause) to `faults/fault-log.md`.

The resource faults each break things a different way and teach a different lesson. **F4** and **F8**
strangle a service's CPU/memory with `docker update` while everything else stays healthy. **F9**
reproduces the documented ["CPU exhausted"](https://openvidu.io/latest/docs/troubleshooting/recording/#cpu-exhausted)
recording failure *without* loading the host: it injects an impossible `room_composite_cpu_cost` into
`egress.yaml`, so egress's admission control refuses every recording with the exact documented signature
— `not enough cpu for some egress types` and `can not accept request … reason:"cpu" … "not enough CPU"`
— while calls carry on untouched.

## Under the hood

| Piece | What runs it |
|---|---|
| Grafana MCP (read-only) | `docker run grafana/mcp-grafana` on the lab network, token from `.state/mcp.env` |
| Load generator | `docker run livekit/livekit-cli` (see `load.sh`) |
| Ingress driver (F7) | `docker run jrottenberg/ffmpeg` |
| Fault injection | `docker` / `iptables` / `tc` **inside** the VM (over SSH) |

The `.mcp.json` files are Docker-based and contain **no token** — the read-only credential
lives only in `.state/mcp.env` (git-ignored), loaded via `docker --env-file`. Launch Claude
from inside the arm directory (`cd mcp/control`) so that relative path resolves.

## Reproducibility

Every version is pinned, so the lab behaves identically every time: OpenVidu `3.8.0` (which
bakes in the exact tags for its whole stack), `openvidu-fake-vm` `v0.1.0`, and the three
tooling images (Grafana MCP, LiveKit CLI, ffmpeg) by immutable `@sha256` digest. Full
breakdown and how to bump a pin: **[VERSIONS.md](VERSIONS.md)**.

## Teardown

```bash
./down.sh            # revert faults, stop load, remove the VM (keeps .state secrets)
./down.sh --purge    # also wipe .state and the fake-vm clone
```

## Layout

```
up.sh / down.sh / load.sh / scenario.sh   # lifecycle + the one-command-per-scenario front door
env.sh                                     # shared config (sources .state/lab.env if present)
faults/                                    # one script per fault + lib.sh + fault-log.md (runtime)
mcp/control  · mcp/with-skill              # the two blind-session arms (dockerised MCP; skill in with-skill)
prompts/scenarios.yaml                     # operator prompt + answer key per scenario
runner/                                    # headless harness (run-session.sh, run-both-arms.sh)
.state/                                    # runtime secrets + token (git-ignored, never committed)
```

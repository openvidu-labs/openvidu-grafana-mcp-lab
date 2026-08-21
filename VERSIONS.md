# Pinned versions

Everything this lab depends on is pinned, so it behaves **identically every time**,
regardless of what floating tags point to in the future. The single source of truth is
[`env.sh`](env.sh) (plus the MCP image digest hard-coded in the two `mcp/*/.mcp.json`).

## What we pin directly

| Component | Version | Pinned in |
|---|---|---|
| OpenVidu Single Node **Community** | `3.8.0` | `env.sh` → `OV_VERSION` |
| **openvidu-fake-vm** | `v0.1.0` (commit `ef5e57c`) | `env.sh` → `FAKE_VM_REF` |
| **Grafana MCP** (`grafana/mcp-grafana`) | digest `sha256:f21a19ce…16e5f` | `env.sh` → `MCP_IMAGE` **and** both `mcp/*/.mcp.json` |
| **LiveKit CLI** (`livekit/livekit-cli`) | `lk 2.18.2`, digest `sha256:c118853d…8d962` | `env.sh` → `LK_IMAGE` |
| **ffmpeg** (`jrottenberg/ffmpeg`) | `8.0`, digest `sha256:50171be5…4a187` | `env.sh` → `FFMPEG_IMAGE` |

The three tooling images are pinned by **immutable digest** (`@sha256:…`), which — unlike a
`:latest` or even a `:1.2.3` tag — can never be repointed at a different build.

## What OpenVidu 3.8.0 pins for us

Pinning `OV_VERSION=3.8.0` pins the **entire** deployment: the official
`get.openvidu.io/community/singlenode/3.8.0/install.sh` bakes in exact image tags for every
service. The ones this lab observes and breaks, for reference:

| Service | Image tag (OpenVidu 3.8.0) |
|---|---|
| OpenVidu Server / Egress / Ingress / Operator / Dashboard / Meet | `openvidu/*:3.8.0` |
| Grafana | `grafana/grafana:12.4.4` |
| Mimir | `openvidu/grafana-mimir:3.1.0-r0` |
| Loki | `openvidu/grafana-loki:3.7.2-r0` |
| Prometheus | `prom/prometheus:v3.12.0` |
| Grafana Alloy | `grafana/alloy:v1.17.0` |
| Redis | `redis:8.6.4-alpine` |
| MongoDB | `mongo:8.0.26` |
| MinIO | `openvidu/minio:RELEASE.2026-06-04T00-54-11Z-r0` |
| Caddy | `openvidu/openvidu-caddy:3.8.0` |
| Docker / Compose (installed in the VM) | `29.5.3` / `v5.1.4` |

## Residual dependencies we can't pin (documented honestly)

- **`ubuntu:24.04`** — the base image of `openvidu-fake-vm`. Pinning the fake-vm release pins
  its Dockerfile, but the Ubuntu base still tracks the latest 24.04 patch level. Stable within
  the LTS; not a behavioural concern for this lab.
- **`playground.openvidu-local.dev` → `10.5.0.3`** and the wildcard TLS certificate served from
  **`certs.openvidu-local.dev`** are public services OpenVidu maintains. They're what give the
  lab a real domain and trusted HTTPS with zero setup; they aren't ours to pin.

## Updating a pin

1. Edit the value in `env.sh` (and, for the MCP image, the digest in **both** `mcp/*/.mcp.json`).
2. `./down.sh --purge && ./up.sh` for a clean rebuild.

To refresh a tooling digest to the current `:latest`:

```bash
docker pull grafana/mcp-grafana:latest
docker inspect --format '{{index .RepoDigests 0}}' grafana/mcp-grafana:latest
```

---
name: openvidu-grafana-triage
description: >-
  Triage and root-cause OpenVidu / LiveKit WebRTC production incidents using ONLY a read-only
  Grafana MCP (dashboards, Prometheus/Mimir metrics, Loki logs). Use when an operator reports a
  video-conferencing problem and you have Grafana access but no shell, source, or other tooling.
  Triggers: "calls broken / no audio or video", "people join but can't see each other",
  "calls are choppy / freezing / bad quality", "a bunch of calls dropped", "recordings aren't
  showing up / egress failing", "can't start new rooms", "RTMP/WHIP ingest not coming through",
  "participant cap / rooms die after a few minutes", OpenVidu, LiveKit, SFU, WebRTC, ICE, egress,
  ingress observability.
---

# OpenVidu / LiveKit triage via Grafana MCP

You are debugging an **OpenVidu Pro** deployment (a LiveKit-based WebRTC stack) through Grafana
**only**. No shell, no source, no `openvidu-logs-cli` — dashboards, Prometheus/Mimir metrics, and
Loki logs are your entire world. Recommend fixes; never mutate anything.

## Mental model — three planes
- **Signal/routing plane** (master node): `redis` (coordination/routing), `mongo` (state),
  `caddy` (TLS + Pro license), `minio` (recording storage), `operator`. If this breaks, the
  cluster mis-coordinates but individual media may still flow.
- **Media plane** (media nodes): `openvidu` (the SFU), `egress` (recording/streaming),
  `ingress` (RTMP/WHIP in). This is where ICE/DTLS/RTP live.
- **Observability**: metrics via Prometheus→Mimir (datasource `openvidu-prometheus`), logs via
  Alloy→Loki (datasource `openvidu-loki`), shown in Grafana.

**Crucial caveat:** the shipped dashboards only chart the **SFU** (rooms, participants, tracks,
packet bytes, packet loss, quality score). There are **no panels for egress, ingress, redis,
mongo, or minio** — and egress/ingress emit **no Prometheus metrics at all** here, so a recording
or ingest failure is invisible in *every* metric and dashboard. For those subsystems, **Loki logs
are the only signal** (`{container="egress"}`, `{container="ingress"}`, `{container="redis"}`, …).
*Absence of a panel — or of a metric — is not absence of a fault.*

## The 6-step workflow

**0 — Connect.** `list_datasources` → confirm `openvidu-prometheus` and `openvidu-loki` UIDs.

**1 — Orient.** `search_dashboards` (query "openvidu") → `get_dashboard_summary` /
`get_dashboard_panel_queries` on the metrics dashboard. Run its key panels to see the shape of the
incident: are participants present? is media flowing? is quality dropping?

**2 — Localize with metrics.** `query_prometheus` (range queries) on the signal table below.
Use `list_prometheus_label_values` on `media_node_id` / `instance` to find *which* node. A series
that has **disappeared** is itself the signal (node/registration loss).

**3 — Pivot to logs.** `list_loki_label_values` for `container`, then `query_loki_logs` scoped
`{container="…"}` (optionally `,level="error"` or `,room_id="…"`) *before* adding a line filter
`|~ "(?i)…"`. Use `query_loki_patterns` / `find_error_pattern_logs` to surface elevated errors.

**4 — Correlate.** Tie metric anomalies and log lines together by `room_id`, `node_id`,
`media_node_id`, and time window.

**5 — Conclude.** State the **subsystem + specific mechanism**, the evidence, and a **remediation
that maps to a config lever** (below). If metrics/logs are nominal, say so — it may be client-side,
not a server fault. Optionally `generate_deeplink` to hand back an Explore/panel URL.

## Signal table (real metric + log signatures)

Metrics are `livekit_*` in datasource `openvidu-prometheus`. Common labels: `media_node_id`,
`node_id`, `instance`, `room_id`, `state`. Loki labels: `container, service_name, level,
node_id, node_ip, room_id, cluster_id`.

| Symptom / hypothesis | Metric signal | Log signal (Loki) | Likely lever |
|---|---|---|---|
| **No media though people join (ICE/UDP)** | `livekit_participant_total` > 0 & `signal_connected` climbs, but `rate(livekit_packet_bytes[1m])` ≈ 0; `livekit_peer_connection_state{state="started"}` piles up while `ice_connected`/`fully_established` don't | `{container="openvidu"} |~ "(?i)ice|candidate"` → "Failed to ping without candidate pairs / connection is not possible" | firewall/security-group blocking WebRTC media ports; `rtc` port range, `use_external_ip`/`node_ip` |
| **Capacity / overload** | per-`media_node_id` `livekit_participant_total` plateaus; `histogram_quantile` on `livekit_quality_score_bucket` drops; `rate(livekit_packet_loss_percent_sum)` up; node packet drops | quality/drop warnings | add media nodes / reduce load |
| **Media-node death / dereg** | a `media_node_id`/`instance` series **vanishes**; cluster participant step-down | `{container="openvidu"} |~ "(?i)dead|unregist|remove.*node"` | restart/replace node; find why it died |
| **Recordings not landing in storage** | No metric/panel at all — log-only. | The **operator** health-monitors containers: `{container="operator",level="error"} |~ "(?i)minio"` → "Container 'minio' error" when the storage backend is down. Also `{container="egress"} |~ "(?i)upload\|s3\|minio\|denied"`, and check whether `minio` still appears in `list_loki_label_values(container)`. | restart/restore MinIO; check storage health & creds |
| **Egress crash / CPU** | egress has no metrics → logs only | `{container="egress"} |~ "(?i)chrome|gstreamer|oom|killed|panic"` | more CPU / lower concurrency |
| **Redis down (coordination)** | SFU metrics **freeze** (stop advancing); new rooms don't appear | `{container="openvidu"} |~ "(?i)redis"` / `{container="egress"} |~ "not connected"` | restore Redis; check address/health |
| **License eval cap (Pro)** | `livekit_participant_total` pinned at a low ceiling; `livekit_room_duration_seconds` capped | `{container=~"openvidu.*"} |~ "(?i)eval|license"` | install a valid Pro license |
| **Ingress (RTMP/WHIP) failing** | *no panel*; `livekit_ingress_*` counters | `{container="ingress"} |~ "(?i)rtmp|whip|connect|transcode|codec"` | unblock RTMP 1935 / fix stream key / CPU |

## Guardrails
- Read-only. Never call write/mutating tools. Never echo the service-account token.
- Don't invent metric names, nodes, or rooms — confirm them via `list_prometheus_metric_names`,
  `list_prometheus_label_values`, `list_loki_label_values` before asserting.
- Distinguish a **server-side fault** from a **client-side** report; don't manufacture a cause.
- Metric **absence** (a gone series, an empty egress bucket's failing uploads) is evidence too.

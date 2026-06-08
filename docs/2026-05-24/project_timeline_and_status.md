# AI-SOC Project - Timeline and Status
## Snapshot: 2026-05-24

This is the master "front-door" document for the AI-SOC portfolio project.
It ties together the per-day session logs (`operations.md`, `day2/3/4` files,
`m3_observability_setup.md`, etc.) into one chronological narrative and
gives a single consolidated view of what is done and what remains.

For implementation details on any individual item, follow the source link
in each section.

---

## 1. Project Overview

**What this is:** A portfolio-grade AI-augmented Security Operations Center
(SOC) modeled on the OnyxLab AI-SOC reference architecture
(https://research.onyxlab.ai/ai-soc/). Built from scratch on commodity
hardware to demonstrate end-to-end SOC operations enriched by local AI.

**Why it exists:** Resume / interview differentiator. The killer story is
real attack -> Wazuh detection -> AI triage with MITRE context -> auto-created
TheHive case -> automated IOC enrichment via Shuffle -> Discord alert if
high risk - all without any cloud dependency.

**Scope:** Phases 1-4 of the OnyxLab plan (SIEM, SOAR, AI services,
observability). Phase 5 (NIDS via Suricata/Zeek on a 4th WSL2 node) was
in scope originally but currently dropped to keep the timeline realistic;
may revisit later.

**Hardware split (3 Windows machines, no GPU on any host):**

| Machine | Role | RAM | LAN IP | Runtime |
|---|---|---|---|---|
| M1 | SIEM + SOAR (Wazuh, TheHive, Cortex, Shuffle) | 16 GB | 192.168.100.124 | Docker Desktop + WSL2 |
| M2 | AI services (FastAPI, ChromaDB, Ollama) | 16 GB | 192.168.100.152 | Docker Desktop + WSL2 + native Ollama |
| M3 | Observability (Prometheus, Grafana, Loki, etc.) | 8 GB | TBD (mis-detected as 192.168.34.1) | Docker Desktop + WSL2 |

**Key design choices already locked in:**

- LLM is local Ollama with `llama3.2:3b` (no cloud API keys for AI)
- ML ensemble: Random Forest + XGBoost + Decision Tree trained on CICIDS2017
- RAG corpus: MITRE ATT&CK techniques indexed in ChromaDB
- Network IDS replaced by Sysmon + Wazuh Agent (all hosts are Windows)
- Risk score formula:
  `(ml_confidence * 0.4 + rag_similarity * 0.3 + (severity/15) * 0.3) * 100`
- Repo: https://github.com/nizaryart/ai-soc-platform (Apache 2.0)

---

## 2. Timeline

### 2026-05-16 - Project conception

- Hardware confirmed (M1 + M2 + M3, all Windows, no GPU)
- Initial 2-day timeline rejected in favor of 5-7 days at full quality
- Working directory established at `C:\Users\pc\Desktop\The advanced Soc real market project`
  with only `implementation_plan_3_machines.md` and 3 architecture jpgs

### 2026-05-17 - Phase 1 SIEM deployed (M1)

Source: `docs/operations.md` (Deploy log section)

- Wazuh Manager + Indexer + Dashboard stack up via
  `docker-compose/phase1-siem-core-windows.yml`
- TLS certs generated via `scripts/generate-certs.ps1` (copied from upstream
  OnyxLab, fixed to include UTF-8 BOM for PowerShell)
- Wazuh API password set to `Wazuh.API.Pass.2026` (complexity requirement)
- Wazuh index template loaded manually (Filebeat sometimes skips this on
  first boot - documented as one-time post-deploy step)
- All 25 upstream config files normalized from CRLF to LF line endings
  (Wazuh csyslogd parser breaks on `\r` characters with cryptic "line 0"
  errors)
- `.gitattributes` added to force LF on `.conf`/`.yml`/`.yaml`/`.xml`/`.json`/
  `.cnf`/`.sh`/`.ps1` files

### 2026-05-17 to 2026-05-19 - Phase 2 SOAR deployed (M1)

Sources: `docs/phase2_explanation.md`, `docs/initial_boot.txt`

- Stack: Cassandra 4.1.3, MinIO, OpenSearch 1.3.20 (downgraded from 2.11.1
  due to Cortex 3 `include_type_name` incompatibility), TheHive 5.2.9,
  Cortex 3.1.7, Shuffle 1.4.0 (backend, frontend, orborus)
- 4 upstream OnyxLab bugs fixed during deployment:
  1. Broken `shuffle-database` service (used legacy `frikky/shuffle:app_sdk`
     image with a `-database` arg that no longer exists) - removed entirely;
     modern Shuffle uses OpenSearch directly
  2. Shuffle frontend port mapping wrong (`3000->80` instead of `80`)
  3. Shuffle frontend missing `soar-backend` network attachment
  4. Cortex healthcheck auth issue
- TheHive auth providers fixed (added `session` provider - UI cookie auth
  was broken without it)
- TheHive admin password rotation deferred (default admin/admin still active;
  documented blocker in `operations.md`)
- Cortex configured with `analyzer.urls` (not deprecated `analyzer.path`)
  and `/var/run/docker.sock` mount for analyzer container spawn
- First-run wizards completed for TheHive, Cortex, Shuffle, MinIO (login
  flows in `docs/initial_boot.txt`)

### 2026-05-21 - Phase 3 AI Services deployed (M2)

Source: end-to-end proof captured in conversation (TheHive case `~4128`)

- 7 FastAPI services deployed via `docker-compose/ai-services.yml`:
  - `wazuh-integration` (port 8002) - webhook entrypoint
  - `alert-triage` (8100) - orchestrator
  - `ml-inference` (8500) - RF/XGB/DT ensemble
  - `rag-service` (8300) - ChromaDB-backed MITRE retrieval
  - `feedback-service` (8400)
  - `correlation-engine` (8600)
  - `response-orchestrator` (8800)
  - `rule-generator` (8700)
- ChromaDB v2 (port 8200) for RAG vector storage
- Native Ollama on M2 (not in Docker) with `llama3.2:3b` quantized model
  via `host.docker.internal` from container side
- Original contribution: `thehive_client.py` written (~230 lines) - fills
  gap in upstream OnyxLab which declared `thehive_url`/`thehive_api_key`
  but had no actual client code. See `docs/thehive_integration.md`
- Several env-var propagation bugs fixed (compose `.env` is for substitution
  only - containers need explicit `environment:` blocks)
- LLM timeout extended from 60s to 300s for CPU inference
- Postgres password URL-encoding fix (`@` characters break `postgresql://`)
- **End-to-end success:** synthetic alert POST to `:8002/webhook` produced
  TheHive case `~4128` at http://192.168.100.124:9010/cases/~4128/details
  with severity=HIGH, confidence=0.92, structured recommendations, MITRE
  tags, observables. Latency: ~60-90s per alert (LLM dominated).

### 2026-05-22 - Cortex/cortexutils incompatibility, SOAR pivot

Source: `docs/operations.md` section 4

- Cortex 3.1.7 (from 2022) passes analyzer input via `/job/input/input.json`,
  but the modern `ghcr.io/thehive-project/*` analyzer images (rebuilt 2025)
  use `cortexutils` from `sys.stdin`. Stdin is empty -> JSON decode error
  on empty string. Upstream maintenance gap.
- Architectural decision: SOAR workflows pivot to **Shuffle native apps**
  for IOC enrichment (AbuseIPDB, VirusTotal, OTX, MaxMind). Cortex remains
  deployed but for manual analyst use only.
- 3 threat-intel Shuffle apps imported via UI: AbuseIPDB (id
  `cd7361fa1d3d1be2f9cff9ee51d3f12f`), AlienvaultOTX
  (`df6f58f97aa27bb67f237fe57c625db0`), Virustotal_v3
  (`0f560425f9c0c4618f970d6e3775b5a4`). Each app activated, is_valid=true.
- TheHive notification rule attempted in UI - did not fire (see Day 4)

### 2026-05-22 to 2026-05-23 - Day 4: Shuffle pipeline bug-hunt

Source: `docs/day4_shuffle_pipeline_fixes.md` (full details)

Six discrete bugs found and fixed end-to-end:

1. TheHive notification config key wrong (`notification.webhook.endpoints`
   does not exist in TheHive 5; correct key is `notification.endpoints`
   with `type: webhook` discriminator). Discovered by unpacking
   `org.thp.thehive-core-5.2.9-1.jar` and reading bytecode strings.
2. Duplicate UI-created webhook endpoint with bad URL - deleted, rule
   recreated pointing to config-loaded endpoint
3. shuffle-backend zombie network attachment (container claimed network
   membership but had empty `EndpointID`/`IPAddress`); fixed by
   `docker compose up -d --force-recreate shuffle-backend`
4. Orborus polled environment `Shuffle` but only `Org_default` existed;
   fixed `ENVIRONMENT_NAME=Org_default` in compose
5. Worker image path `ghcr.io/frikky/shuffle-worker:1.4.0` did not exist
   (Shuffle moved to `ghcr.io/shuffle/...` org); side-effect of changing
   `SHUFFLE_BASE_IMAGE_NAME=shuffle` was orborus deleting backend +
   frontend containers, identifying them as old workers. Workaround:
   keep env var as `frikky` and locally `docker tag` the new image under
   the old name
6. Worker `BASE_URL=http://shuffle-backend:5001` unreachable from worker
   containers (they spawn on default bridge network, not soar-backend);
   changed to `http://host.docker.internal:5001`

**Result:** TheHive case create -> webhook fires -> Shuffle workflow
triggered -> worker containers spawn -> actions execute. Pipeline is
fully operational end-to-end. Current workflow still has placeholder
nodes (`set_cache_value`, `get_cache_value`, `repeat_back_to_me`) - actual
IOC enrichment logic is the next step.

### 2026-05-24 - M3 Observability prep

Source: `docs/2026-05-24/m3_observability_setup.md`

- `scripts/setup-m3.ps1` written - generates configs for the 6-service
  observability stack
- v1 had PowerShell parse errors on M3 (French Windows + em-dashes in
  here-strings caused encoding issues)
- v2 rewrite: ASCII-only, single-quoted here-strings (`@'...'@`) with
  `.Replace()` substitution, explicit UTF-8-without-BOM writes via
  `[System.IO.File]::WriteAllText`
- v2 ran successfully on M3 - 14 directories created, 8 config files
  written, 6 Docker images pre-pulled
- windows_exporter installed on all 3 machines (winget package ID was
  wrong - direct MSI download from
  https://github.com/prometheus-community/windows_exporter/releases)
- Firewall ports 9182 + 8081 opened on M3
- **Stack not yet started** - blocked on wrong M3 IP detection
  (`192.168.34.1` is a virtual adapter, not the LAN IP)

---

## 3. What is DONE

Status legend: ✅ working / ⚠️ deployed but degraded / 📝 partial / ❌ not done

### Machine 1 - SIEM + SOAR

| Component | Status | Notes / Source |
|---|---|---|
| Wazuh Manager 4.8.2 | ✅ | `phase1-siem-core-windows.yml` |
| Wazuh Indexer 4.8.2 | ✅ | OpenSearch-based, port 9200 |
| Wazuh Dashboard 4.8.2 | ✅ | https://192.168.100.124:443 |
| Wazuh admin password | ⚠️ | Still admin/admin - rotation blocked, see `operations.md` |
| Wazuh index template auto-load | ⚠️ | Manual load required first time; documented |
| TheHive 5.2.9 | ✅ | http://192.168.100.124:9010 |
| TheHive UI session auth | ✅ | `application.conf` session provider added |
| TheHive notification -> Shuffle webhook | ✅ | Day 4 fixes |
| Cortex 3.1.7 | ⚠️ | Deployed, analyzer execution broken (cortexutils drift). API integration with TheHive works |
| Shuffle 1.4.0 backend | ✅ | http://192.168.100.124:5001 (label says unhealthy - cosmetic) |
| Shuffle 1.4.0 frontend | ✅ | http://192.168.100.124:3001 |
| Shuffle 1.4.0 orborus | ✅ | Polls `Org_default` env, spawns workers |
| Shuffle OpenSearch 1.3.20 | ✅ | Port 9201 |
| Shuffle 3 threat-intel apps | ✅ | AbuseIPDB, VirusTotal v3, AlienvaultOTX - imported and active |
| Cassandra 4.1.3 | ✅ | TheHive backing store |
| MinIO | ✅ | TheHive object storage |
| Stale `EXECUTING` workflow ghosts | ⚠️ | Several from Day 4 iteration; not blocking but UI clutter |

### Machine 2 - AI Services

| Component | Status | Notes |
|---|---|---|
| postgres:16-alpine | ✅ | Port 5435 |
| wazuh-integration | ⚠️ | Healthy paths work; healthcheck label says unhealthy (cosmetic). Port 8002 |
| alert-triage | ✅ | Port 8100, orchestrates ML/RAG/LLM/TheHive |
| ml-inference | ✅ | Port 8500, RF/XGB/DT ensemble |
| rag-service | ✅ | Port 8300, ChromaDB-backed MITRE retrieval |
| chromadb | ⚠️ | v2 API alive (`/api/v2/heartbeat` returns); healthcheck checks deprecated `/api/v1/` so label is unhealthy (cosmetic). Port 8200 |
| feedback-service | ⚠️ | Port 8400. Deployed and healthy, but NO caller wired in yet (no analyst UI or hook writes to it). Scaffolded. |
| correlation-engine | ⚠️ | Port 8600. Called by alert-triage but returns empty `incident_id`/`kill_chain_stage` in current tests. Either bug or test alerts don't match trigger conditions - never investigated. |
| response-orchestrator | ⚠️ | Port 8800. NOT in original architecture diagram - added by us for Workflow 2. Currently unused (Workflow 2 not designed). |
| rule-generator | ⚠️ | Port 8700. Deployed and healthy, but no scheduled job calls it and no integration to deploy generated rules into Wazuh. Scaffolded. |
| Ollama native + llama3.2:3b | ✅ | Reachable via `host.docker.internal:11434` |
| TheHive client (original contribution) | ✅ | `thehive_client.py`, see `docs/thehive_integration.md` |
| End-to-end pipeline (synthetic alert -> TheHive case) | ✅ | Proof: case `~4128` |
| MITRE techniques in case tags | ⚠️ | Empty - Day 3 Part B unfixed |

### Machine 3 - Observability

| Component | Status | Notes |
|---|---|---|
| Docker Desktop | ✅ | server v29.4.3 |
| `setup-m3.ps1` script | ✅ | v2 ASCII-only, idempotent |
| Config files generated | ✅ | 8 files under `config/` (but with wrong M3 IP baked in) |
| Docker images pre-pulled | ✅ | 6 images, ~3 GB |
| windows_exporter installed | ✅ | All 3 machines, port 9182 |
| Firewall ports on M3 | ✅ | 9182, 8081 open |
| Firewall ports on M1, M2 | ❌ | Port 9182 not opened yet |
| Stack started (`docker compose up -d`) | ❌ | Blocked - need correct IP first |
| Grafana dashboards imported | ❌ | Pending stack start |
| Wazuh Agent on M3 | ❌ | Not installed |

### Cross-cutting

| Item | Status | Notes |
|---|---|---|
| Git repo at github.com/nizaryart/ai-soc-platform | ✅ | Apache 2.0 |
| `.gitignore` correct (no `.env` tracked) | ✅ | Fixed during Day 2 (leading-spaces bug) |
| `.gitattributes` enforces LF | ✅ | Prevents Wazuh CRLF parser breakage |
| Documentation (per-day session logs) | ✅ | 8 files in `docs/` |
| Master timeline doc | ✅ | This file |

---

## 4. What REMAINS

### Priority 1 - unblock M3 stack startup (do first)

- [ ] On M3, find real LAN IP:
  ```powershell
  Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -like "192.168.100.*" } |
    Select-Object IPAddress, InterfaceAlias
  ```
- [ ] Re-run `setup-m3.ps1` with correct IP + Discord webhook:
  ```powershell
  cd C:\AI_Soc_P\ai-soc-portfolio
  .\scripts\setup-m3.ps1 `
    -M3_IP "192.168.100.X" `
    -DiscordWebhookUrl "https://discord.com/api/webhooks/1507397600121323670/zoZ4dgChN_VMDdoWBTHJ_lmi0ZAvdxFFlCY6JIX0-xNHB3Ni8U1TeHr5-7Wa2JsdV45F" `
    -SkipImagePull
  ```
- [ ] Open firewall port 9182 inbound on M1 and M2:
  ```powershell
  New-NetFirewallRule -DisplayName 'Prom windows_exporter' -Direction Inbound -Protocol TCP -LocalPort 9182 -Action Allow
  ```
- [ ] Start the M3 stack:
  ```powershell
  cd C:\AI_Soc_P\ai-soc-portfolio\docker-compose
  docker compose -f observability.yml up -d
  ```
- [ ] Verify 6 services healthy via `docker compose ps`
- [ ] Verify Prometheus is scraping windows_exporter on all 3 hosts:
  http://<M3_LAN_IP>:9090/targets
- [ ] Verify Loki ready: `Invoke-RestMethod http://localhost:3100/ready`
- [ ] Open Grafana (admin / AiSocGrafana2026!) and import dashboards
  14694 (windows_exporter), 893 (cAdvisor), 13639 (Loki logs)

### Priority 2 - Workflow 1 (IOC Enrichment) - replace placeholder nodes

Currently the Shuffle workflow has scaffold nodes only. Needs:

- [ ] Fix TheHive webhook body (currently sends empty body; Shuffle backend
      logs `body of length 0`). Investigate the `version` field on
      WebhookEndpoint or switch to `type: http` with `bodyTemplate`
- [ ] Stop and clean up stale `EXECUTING` ghost executions from Day 4
      iteration (Shuffle UI -> Workflows -> executions tab)
- [ ] Build out the real flow in Shuffle UI:
  - Extract case ID + observables from webhook payload
  - Branch by observable type (IP -> AbuseIPDB; IP/domain/hash -> VirusTotal,
    OTX)
  - Python aggregator node computing `risk_score` 0-100
  - TheHive update-case action: set custom field `risk_score`, add
    comment with enrichment results
  - Conditional: if score >= 70 -> Discord webhook
- [ ] End-to-end test with a fresh alert from M2

### Priority 3 - Day 3 deferred items

Source: `docs/day3_remaining.txt`

- [ ] **Part A:** Wire real Wazuh webhook -> M2 AI (replace synthetic
      `curl POST :8002/webhook`)
  - Add `<integration>` block to M1's `ossec.conf` (level >= 7, json
    format, hook_url -> http://192.168.100.152:8002/webhook)
  - Copy/adapt a Wazuh custom-webhook Python helper into
    `/var/ossec/integrations/`
  - Restart wazuh-manager, trigger real failed-logon attack, verify chain
- [ ] **Part B:** Fix empty `mitre_techniques` field
  - Strengthen LLM prompt template in `services/alert-triage/llm_client.py`
    to explicitly require populated `mitre_techniques` array
  - Add deterministic fallback: if LLM output has empty list but RAG
    returned techniques, populate `mitre_techniques` from RAG directly

### Priority 4 - Workflow 2 (High-Risk Auto-Response)

Not designed yet. Concept sketch:

- [ ] If risk_score >= 90, automatically:
  - Tell Wazuh to isolate the host (via Active Response)
  - Tell TheHive to escalate the case (status -> InProgress, severity -> 4)
  - Post a high-priority Discord alert with the case link
  - Optionally disable the user account (Active Directory or local)

### Priority 5 - M1/M2 additions for full observability coverage

Currently Prometheus on M3 will show M1/M2 cAdvisor and most AI service
`/metrics` targets as DOWN. To fix:

- [ ] Add `cadvisor` service block (port 8081) to
      `docker-compose/phase1-siem-core-windows.yml`
- [ ] Add `cadvisor` service block to `docker-compose/phase2-soar-stack.yml`
      (or merge into the phase1 one)
- [ ] Add `cadvisor` service block to M2's `docker-compose/ai-services.yml`
- [ ] Add `promtail` service block on M1 and M2, configured to push to
      `http://<M3_LAN_IP>:3100/loki/api/v1/push`
- [ ] Open firewall port 8081 inbound on M1 and M2
- [ ] Add `prometheus-fastapi-instrumentator` (or equivalent) to M2's
      FastAPI services so they expose `/metrics`
- [ ] (Optional) Install OpenSearch Prometheus Exporter plugin on the
      Wazuh Indexer so `wazuh_indexer` scrape job returns real data

### Priority 6 - M3 endpoint integration

- [ ] Install Wazuh Agent on M3 (MSI from
      https://packages.wazuh.com/4.x/windows/, manager IP = 192.168.100.124)
- [ ] (Optional) Install Sysmon on M3 for richer endpoint telemetry

### Priority 7 - Day 2 deferred polish

Source: `docs/day2_yet_todo_requirements.txt` (17 items). None blocking.
Examples:

- [ ] Wazuh admin password rotation (full procedure already documented in
      `operations.md` section 1)
- [ ] Fix cosmetic `unhealthy` healthcheck labels on TheHive, Cortex,
      Shuffle-backend, ChromaDB, wazuh-integration (healthcheck endpoint
      paths are wrong - services themselves work)
- [ ] Set up DHCP reservations on router so machine IPs do not drift
- [ ] (See `day2_yet_todo_requirements.txt` for the full 17)

### Priority 8 - Portfolio differentiation

- [ ] (Originally planned, dropped from scope) 4th node WSL2 NIDS sensor
      with Suricata + Zeek. Revisit if time allows after Workflows 1+2 ship.

**Note (2026-05-27):** Command Center was in the original M3 architecture
diagram but has been **explicitly removed from scope**. Reason: it would
have been a custom analyst-facing dashboard duplicating data already
visible via Grafana + TheHive UI + Wazuh Dashboard. Decision: keep the
existing dashboards rather than build a meta-dashboard on top.

### Priority 9 - Documentation cleanup

- [ ] Add `docs/README.md` with a one-line description of each doc file
- [ ] Consider consolidating `initial_boot.txt`, `phase2_explanation.md`,
      and `thehive_integration.md` - they cover related ground and might
      read better as one doc
- [ ] Per-day session logs (`day2_yet_todo_requirements.txt`,
      `day3_remaining.txt`, `day4_shuffle_pipeline_fixes.md`) should stay
      as historical record; this master doc supersedes them as the
      "current status" view

### Priority 10 - Demo / recording phase

Once Workflows 1 + 2 are real, record the resume/interview-defining
screencast:

- [ ] Trigger a real attack on M2 or M3 (failed-logon brute force, or
      Mimikatz-like credential access)
- [ ] Show Wazuh detecting in the dashboard
- [ ] Show M2 alert-triage logs streaming the AI analysis
- [ ] Show the TheHive case appearing with AI tags + observables
- [ ] Show Shuffle workflow auto-enriching IOCs (AbuseIPDB / VT / OTX)
- [ ] Show risk score crossing threshold -> Discord notification
- [ ] Show analyst opening the case with full enriched context

This clip is the entire point of the project. Everything else is build-up.

---

## Sources of truth (for details, follow these)

| Doc | Covers |
|---|---|
| `docs/operations.md` | Wazuh password rotation procedure, Cortex incompatibility, deploy log |
| `docs/initial_boot.txt` | SOAR first-run wizards (TheHive, Cortex, Shuffle, MinIO) |
| `docs/phase2_explanation.md` | SOAR architecture deep-dive, 4 upstream bugs fixed |
| `docs/thehive_integration.md` | TheHive client design (original contribution) |
| `docs/day2_yet_todo_requirements.txt` | Day 2 deferred items (17) |
| `docs/day3_remaining.txt` | Day 3 Parts A and B (real Wazuh webhook, MITRE empty) |
| `docs/day4_shuffle_pipeline_fixes.md` | 6 Shuffle pipeline bug fixes |
| `docs/2026-05-24/m3_observability_setup.md` | Today's M3 prep session |
| `docs/2026-05-24/project_timeline_and_status.md` | This file - master view |

---

## How to verify this snapshot is still current

If you come back to this doc days later, sanity-check it by running:

```powershell
# M1 - SIEM + SOAR
docker ps --format "table {{.Names}}\t{{.Status}}"

# M2 - AI services
docker compose -f C:\AI_oc_P\ai-soc-portfolio\docker-compose\ai-services.yml ps

# M3 - observability (once started)
docker compose -f C:\AI_Soc_P\ai-soc-portfolio\docker-compose\observability.yml ps

# End-to-end probe (from M2)
$body = @{
  id        = "smoke-$(Get-Date -Format yyyyMMddHHmmss)"
  timestamp = (Get-Date -Format "o")
  rule      = @{ id="5712"; level=10; description="Brute force smoke test" }
  agent     = @{ id="001"; name="test-host"; ip="192.168.100.152" }
  data      = @{ srcip="185.220.101.45"; srcuser="administrator"; dstip="192.168.100.152" }
  full_log  = "Smoke test"
} | ConvertTo-Json -Depth 6
Invoke-RestMethod -Uri "http://localhost:8002/webhook" -Method Post -Body $body -ContentType "application/json"
```

If anything in the "DONE" section above no longer matches the running
state, edit accordingly.

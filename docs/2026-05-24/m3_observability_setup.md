# M3 (Observability Stack) - Setup Session
## Date: 2026-05-24

This document covers what was done on 2026-05-24 toward bringing up Machine 3
(the observability node) of the AI-SOC. M3 is a Windows host with 8 GB RAM,
no GPU. It is supposed to monitor M1 (SIEM + SOAR) and M2 (AI services).
Nothing has been STARTED yet on M3 - this session built the prerequisites
and config files. Stack startup is the next session.

---

## What was DONE this session

### 1. M3 prerequisites verified

- Docker Desktop installed on M3 by user
- Docker engine reachable: server version 29.4.3
- docker compose v2 available: v5.1.4
- Script ran in elevated PowerShell

### 2. Setup script created at scripts/setup-m3.ps1

Two iterations were needed:

- **v1 (parse errors)** - The first version used double-quoted PowerShell
  here-strings (`@"..."@`) for embedded YAML content. PowerShell's parser
  misbehaved on the user's French-locale Windows when the script was
  transferred to M3 (probably encoding-related on em-dash characters).
  Errors looked like:
  ```
  Expression manquante apres l'operateur unaire <<-->>
  Vous devez indiquer une expression de valeur apres l'operateur <<..>>
  ```
  Parser was treating YAML lines inside the here-string as PowerShell code.

- **v2 (working)** - Rewritten with three changes:
  1. ASCII-only content (no em-dashes, no smart quotes)
  2. Single-quoted here-strings `@'...'@` for all YAML blocks - no
     variable expansion inside, parser cannot get confused. Variables
     substituted afterward via `.Replace('__M3__', $M3_IP)` pattern.
  3. Explicit UTF-8-without-BOM writes via
     `[System.IO.File]::WriteAllText(...)` with `new UTF8Encoding($false)` -
     Linux/Docker tools dislike BOMs.

### 3. setup-m3.ps1 v2 ran successfully on M3

Output confirmed:
- 14 directories created under `C:\AI_Soc_P\ai-soc-portfolio\`:
  - `config/prometheus/`, `config/prometheus/rules/`
  - `config/loki/`, `config/promtail/`, `config/alertmanager/`
  - `config/grafana/provisioning/datasources/`
  - `config/grafana/provisioning/dashboards/`
  - `config/grafana/dashboards/`
  - `data/prometheus/`, `data/grafana/`, `data/loki/`, `data/alertmanager/`
  - `docker-compose/`

- 8 config files written:
  - `config/prometheus/prometheus.yml` - scrape jobs for windows_exporter,
    cAdvisor, AI services on M2, Wazuh Indexer, SOAR health
  - `config/prometheus/rules/alerts.yml` - 4 alert rules (TargetDown,
    HostHighMemory, HostHighCpu, ContainerOOMRestart)
  - `config/loki/loki-config.yml` - single-binary, filesystem, 7-day retention
  - `config/promtail/promtail-config.yml` - Docker auto-discovery to Loki
  - `config/alertmanager/alertmanager.yml` - **currently NULL receiver**
    (user did not paste Discord webhook URL on first run)
  - `config/grafana/provisioning/datasources/datasources.yml` - Prometheus +
    Loki auto-wired
  - `config/grafana/provisioning/dashboards/dashboards.yml` - dashboard
    auto-loader from `config/grafana/dashboards/`
  - `docker-compose/observability.yml` - 6-service stack with resource limits

### 4. Six Docker images pre-pulled on M3

  - `prom/prometheus:v2.55.1`
  - `grafana/grafana:11.3.0` (had a transient "unexpected EOF" during pull,
    then retried and finished - **verification recommended**: `docker images
    grafana/grafana:11.3.0`)
  - `grafana/loki:3.2.1`
  - `grafana/promtail:3.2.1`
  - `prom/alertmanager:v0.27.0`
  - `gcr.io/cadvisor/cadvisor:v0.49.1`

### 5. windows_exporter installed on M1, M2, AND M3

Not via winget (`winget install --id=prometheus-community.windows_exporter -e`
returned "No package found matching input criteria"). Installed via direct MSI
download from
https://github.com/prometheus-community/windows_exporter/releases.

Default port: 9182. Registered as Windows service `windows_exporter`.

### 6. Firewall rule added on M3

  ```powershell
  New-NetFirewallRule -DisplayName 'Prom windows_exporter' -Direction Inbound -Protocol TCP -LocalPort 9182 -Action Allow
  New-NetFirewallRule -DisplayName 'cAdvisor'              -Direction Inbound -Protocol TCP -LocalPort 8081 -Action Allow
  ```

---

## What is BROKEN / needs correction before starting the stack

### A. Wrong M3 IP baked into configs

The script auto-detected M3's IP as `192.168.34.1`. That is a **virtual
adapter IP** (likely Hyper-V, WSL, or VMware), NOT M3's LAN IP. M1 and M2
are on `192.168.100.x` and need to be reachable from M3's actual LAN
interface.

Files affected:
- `config/prometheus/prometheus.yml` - `windows_exporter`, `cadvisor`
  scrape jobs include `192.168.34.1:9182` and `192.168.34.1:8081` (those
  won't resolve from outside)
- `docker-compose/observability.yml` - `GF_SERVER_ROOT_URL=http://192.168.34.1:3000`

**Fix:** find the real LAN IP on M3 with
```powershell
Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -like "192.168.100.*" } |
  Select-Object IPAddress, InterfaceAlias
```

Then re-run the script with the correct IP (it will rewrite all files).

### B. Discord webhook not configured

User pressed Enter at the prompt without pasting the webhook URL. Output
showed: `alertmanager.yml written (no notifications)`. AlertManager is
currently wired to a `null` receiver - alerts fire but go nowhere.

**Fix:** include `-DiscordWebhookUrl` on the next re-run of the script.

### C. Firewall ports NOT yet open on M1 and M2

M3's Prometheus will try to scrape windows_exporter on M1 and M2 (port 9182).
Without inbound firewall rules on those machines, scrapes will time out and
those targets will show as DOWN in Prometheus.

**Fix:** on both M1 and M2 (elevated PowerShell):
```powershell
New-NetFirewallRule -DisplayName 'Prom windows_exporter' -Direction Inbound -Protocol TCP -LocalPort 9182 -Action Allow
```

---

## What is REMAINING (not started, in order)

### 1. Fix the IP + Discord URL (re-run script)

Once the real LAN IP is known:
```powershell
cd C:\AI_Soc_P\ai-soc-portfolio
.\scripts\setup-m3.ps1 `
  -M3_IP "192.168.100.X" `
  -DiscordWebhookUrl "https://discord.com/api/webhooks/1507397600121323670/zoZ4dgChN_VMDdoWBTHJ_lmi0ZAvdxFFlCY6JIX0-xNHB3Ni8U1TeHr5-7Wa2JsdV45F" `
  -SkipImagePull
```

`-SkipImagePull` because we already pulled the 6 images in this session.

### 2. Open firewall ports on M1 and M2

See section C above.

### 3. Start the M3 observability stack

```powershell
cd C:\AI_Soc_P\ai-soc-portfolio\docker-compose
docker compose -f observability.yml up -d
```

Wait ~60s, then verify:
```powershell
docker compose -f observability.yml ps
```

Expect 6 services `Up`. cAdvisor may show `unhealthy` (same cosmetic
pattern seen on other stacks - healthcheck endpoint mismatch, but the
service serves traffic).

### 4. Verify each service answers locally

```powershell
Invoke-RestMethod http://localhost:9090/-/healthy   # Prometheus
Invoke-RestMethod http://localhost:3100/ready       # Loki
Invoke-RestMethod http://localhost:9093/-/healthy   # Alertmanager
Invoke-WebRequest  http://localhost:3000/api/health # Grafana
Invoke-RestMethod http://localhost:8081/healthz     # cAdvisor
```

### 5. Verify Prometheus is scraping all targets

Open Prometheus UI: http://M3_LAN_IP:9090/targets

Expected state per target:
- `prometheus` (self) - UP
- `windows_exporter` on M1, M2, M3 (all 3) - UP (once firewall is open
  on M1 and M2)
- `cadvisor` on M3 - UP
- `cadvisor` on M1 - DOWN (cAdvisor not deployed there yet - see step 8)
- `cadvisor` on M2 - DOWN (same reason)
- `ai_services` on M2 ports 8100/8300/8500/8002 - depends on whether those
  FastAPI services expose `/metrics`. They may all be DOWN initially.
- `wazuh_indexer` on M1:9200 - DOWN (no /metrics endpoint by default on
  the Wazuh Indexer; this is informational only)
- `soar_health` targets - probably DOWN (no /metrics on TheHive/Cortex/Shuffle
  by default; intent is just a TCP up-check, may need different config later)

DOWN targets are expected at this stage. They are not failures of the M3
stack; they are pending later wiring.

### 6. Open Grafana and import community dashboards

URL: http://M3_LAN_IP:3000 (admin / AiSocGrafana2026!)

Datasources (Prometheus + Loki) should already be wired by provisioning.

Import dashboards by ID via Grafana UI (+ icon -> Import -> enter ID):
- `14694` - windows_exporter (host CPU/RAM/disk for the 3 machines)
- `893`   - Docker containers (cAdvisor)
- `13639` - Loki logs viewer

### 7. Install Wazuh Agent on M3

So M3 itself shows up in SIEM as a monitored host.

MSI download: https://packages.wazuh.com/4.x/windows/
Manager IP to configure: `192.168.100.124`

### 8. Add cAdvisor + Promtail to M1 and M2 compose files

So Prometheus can scrape container metrics from M1 and M2, and so Promtail
ships their container logs to Loki on M3.

This is a small addition to existing compose files - NOT in scope for this
session. It will require:
- A `cadvisor` service block (port 8081) added to M1's
  `phase1-siem-core-windows.yml` and `phase2-soar-stack.yml`
- A `cadvisor` service block added to M2's `ai-services.yml`
- A `promtail` service block on M1 and M2 pointing
  `clients: [- url: http://M3_LAN_IP:3100/loki/api/v1/push]`
- Firewall rule on M1 and M2: open port 8081 inbound

### 9. Build the Command Center dashboard (portfolio differentiator)

Custom Grafana dashboard (or separate FastAPI/Streamlit app on M3) that
ties everything together: alert volume, MTTD, MTTR, top fired Wazuh rules,
AI confidence distribution, TheHive case statuses, etc.

Intent: a single pane of glass that demonstrates SOC operations to an
interviewer in 30 seconds.

---

## Configuration values used

| Key | Value |
|---|---|
| Repo root on M3 | `C:\AI_Soc_P\ai-soc-portfolio` |
| M1 LAN IP | `192.168.100.124` |
| M2 LAN IP | `192.168.100.152` |
| M3 LAN IP | **TBD** (currently mis-detected as `192.168.34.1`) |
| Wazuh Manager IP | `192.168.100.124` (= M1) |
| Grafana admin password | `AiSocGrafana2026!` |
| Discord webhook | `https://discord.com/api/webhooks/1507397600121323670/zoZ4dgChN_VMDdoWBTHJ_lmi0ZAvdxFFlCY6JIX0-xNHB3Ni8U1TeHr5-7Wa2JsdV45F` |

## Files / artifacts created this session

| Path | Purpose |
|---|---|
| `scripts/setup-m3.ps1` | Idempotent setup script (v2, ASCII-only) |
| `config/prometheus/prometheus.yml` | Scrape config (needs IP fix) |
| `config/prometheus/rules/alerts.yml` | 4 Prometheus alert rules |
| `config/loki/loki-config.yml` | Loki single-binary config |
| `config/promtail/promtail-config.yml` | Promtail (M3-local) Docker log shipper |
| `config/alertmanager/alertmanager.yml` | Currently NULL receiver - needs re-run with Discord |
| `config/grafana/provisioning/datasources/datasources.yml` | Prometheus + Loki datasources |
| `config/grafana/provisioning/dashboards/dashboards.yml` | Dashboard auto-loader |
| `docker-compose/observability.yml` | 6-service stack |
| `docs/2026-05-24/m3_observability_setup.md` | This file |

## Open questions / decisions deferred

- **AI services /metrics endpoint** - do M2's FastAPI services already
  expose Prometheus-format metrics at `/metrics`? If not, that requires
  adding `prometheus-fastapi-instrumentator` (or similar) to each service.
- **Wazuh Indexer Prometheus plugin** - OpenSearch needs a plugin to
  expose Prometheus metrics; the current scrape config is just a placeholder.
- **OnCall integration for AlertManager** - currently only Discord. Could
  add Slack/email later.

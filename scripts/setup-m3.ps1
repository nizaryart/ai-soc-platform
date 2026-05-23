# =============================================================================
# AI-SOC — Machine 3 (Observability Stack) Setup
# =============================================================================
# Bootstraps the full M3 stack:
#   Prometheus + Grafana + Loki + Promtail + AlertManager + cAdvisor + Command Center
#
# WHAT THIS SCRIPT DOES:
#   1. Validates prerequisites (Docker Desktop, network)
#   2. Prompts for M1/M2/M3 IPs and Discord webhook URL
#   3. Creates config files for all 6 services
#   4. Writes docker-compose/observability.yml
#   5. Pre-pulls all required Docker images (~3 GB)
#   6. Prints next steps (start, windows_exporter install)
#
# WHAT IT DOES NOT DO:
#   - Install Docker Desktop (user-driven, requires reboot)
#   - Install Wazuh Agent (user-driven, MSI installer)
#   - Install windows_exporter (user-driven, MSI installer — see end of script)
#   - Start any container (run `docker compose up -d` afterward)
#
# RUN FROM: anywhere on M3, in an elevated PowerShell session.
# =============================================================================

[CmdletBinding()]
param(
    [string]$RepoRoot = "C:\AI_Soc_P\ai-soc-portfolio",
    [string]$M1_IP   = "192.168.100.124",
    [string]$M2_IP   = "192.168.100.152",
    [string]$M3_IP   = "",
    [string]$WazuhManagerIP = "",
    [string]$DiscordWebhookUrl = "",
    [switch]$SkipImagePull
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

function Write-Section($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Ok($msg)      { Write-Host "  [OK]  $msg" -ForegroundColor Green }
function Write-Warn2($msg)   { Write-Host "  [!!]  $msg" -ForegroundColor Yellow }
function Write-Err2($msg)    { Write-Host "  [XX]  $msg" -ForegroundColor Red }

# -----------------------------------------------------------------------------
# 0. Prereq checks
# -----------------------------------------------------------------------------
Write-Section "Prerequisite checks"

# Admin?
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent() `
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warn2 "Not running as Administrator. Some setup steps (firewall, services) may fail later."
} else { Write-Ok "Running elevated" }

# Docker available?
try {
    $dockerVer = (docker version --format '{{.Server.Version}}' 2>$null)
    if ([string]::IsNullOrEmpty($dockerVer)) { throw "no daemon" }
    Write-Ok "Docker engine reachable (server $dockerVer)"
} catch {
    Write-Err2 "Docker engine not reachable. Start Docker Desktop and re-run."
    exit 1
}

# Compose v2?
try {
    $composeVer = (docker compose version --short 2>$null)
    Write-Ok "docker compose v$composeVer"
} catch {
    Write-Err2 "docker compose v2 not available. Update Docker Desktop."
    exit 1
}

# -----------------------------------------------------------------------------
# 1. Gather IPs / secrets
# -----------------------------------------------------------------------------
Write-Section "Configuration parameters"

if (-not $M3_IP) {
    $M3_IP = (Get-NetIPAddress -AddressFamily IPv4 |
              Where-Object { $_.IPAddress -like "192.168.*" -and $_.PrefixOrigin -ne "WellKnown" } |
              Select-Object -First 1 -ExpandProperty IPAddress)
    if ($M3_IP) {
        Write-Ok "Auto-detected M3 IP: $M3_IP"
    } else {
        $M3_IP = Read-Host "M3 IP address"
    }
}

if (-not $WazuhManagerIP) { $WazuhManagerIP = $M1_IP }

if (-not $DiscordWebhookUrl) {
    $DiscordWebhookUrl = Read-Host "Discord webhook URL (blank to skip Alertmanager notifications)"
}

Write-Host ""
Write-Host "  M1_IP            = $M1_IP"
Write-Host "  M2_IP            = $M2_IP"
Write-Host "  M3_IP            = $M3_IP"
Write-Host "  WazuhManagerIP   = $WazuhManagerIP"
Write-Host "  Repo root        = $RepoRoot"
Write-Host "  Discord configured: $([bool]$DiscordWebhookUrl)"

# -----------------------------------------------------------------------------
# 2. Create directory layout
# -----------------------------------------------------------------------------
Write-Section "Creating directory layout"

$dirs = @(
    "$RepoRoot",
    "$RepoRoot\docker-compose",
    "$RepoRoot\config\prometheus",
    "$RepoRoot\config\prometheus\rules",
    "$RepoRoot\config\loki",
    "$RepoRoot\config\promtail",
    "$RepoRoot\config\alertmanager",
    "$RepoRoot\config\grafana\provisioning\datasources",
    "$RepoRoot\config\grafana\provisioning\dashboards",
    "$RepoRoot\config\grafana\dashboards",
    "$RepoRoot\data\prometheus",
    "$RepoRoot\data\grafana",
    "$RepoRoot\data\loki",
    "$RepoRoot\data\alertmanager"
)
foreach ($d in $dirs) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
Write-Ok "Layout created under $RepoRoot"

# -----------------------------------------------------------------------------
# 3. Prometheus config
# -----------------------------------------------------------------------------
Write-Section "Writing Prometheus config"

$prometheusYml = @"
global:
  scrape_interval: 30s
  evaluation_interval: 30s
  external_labels:
    cluster: ai-soc
    site: home-lab

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  # Prometheus itself
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  # Windows hosts (M1, M2, M3) via windows_exporter (port 9182)
  - job_name: windows_exporter
    static_configs:
      - targets:
          - $($M1_IP):9182
          - $($M2_IP):9182
          - $($M3_IP):9182
        labels:
          os: windows

  # Container-level metrics via cAdvisor (port 8081)
  - job_name: cadvisor
    static_configs:
      - targets:
          - $($M1_IP):8081
          - $($M2_IP):8081
          - $($M3_IP):8081

  # AI services on M2 (FastAPI /metrics if exposed; otherwise just up-check)
  - job_name: ai_services
    metrics_path: /metrics
    static_configs:
      - targets:
          - $($M2_IP):8100   # alert-triage
          - $($M2_IP):8300   # rag-service
          - $($M2_IP):8500   # ml-inference
          - $($M2_IP):8002   # wazuh-integration

  # Wazuh Indexer (OpenSearch _prometheus_metrics may need plugin; up-check anyway)
  - job_name: wazuh_indexer
    metrics_path: /
    static_configs:
      - targets: [$($M1_IP):9200]

  # TheHive + Shuffle + Cortex — basic up-check via TCP
  - job_name: soar_health
    static_configs:
      - targets:
          - $($M1_IP):9010   # TheHive UI
          - $($M1_IP):9011   # Cortex UI
          - $($M1_IP):3001   # Shuffle frontend
          - $($M1_IP):5001   # Shuffle backend
"@
$prometheusYml | Out-File -Encoding utf8 -FilePath "$RepoRoot\config\prometheus\prometheus.yml" -NoNewline
Write-Ok "prometheus.yml written"

$alertRulesYml = @"
groups:
  - name: ai-soc-availability
    interval: 30s
    rules:
      - alert: TargetDown
        expr: up == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: 'Scrape target down: {{ `{{ `$labels.job `}}` }} on {{ `{{ `$labels.instance `}}` }}'
          description: 'Prometheus has been unable to scrape {{ `{{ `$labels.instance `}}` }} for 2 minutes.'

      - alert: HostHighMemory
        expr: 100 - (windows_os_physical_memory_free_bytes / windows_cs_physical_memory_bytes * 100) > 92
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: 'Host {{ `{{ `$labels.instance `}}` }} memory > 92%'

      - alert: HostHighCpu
        expr: 100 - (avg by (instance) (rate(windows_cpu_time_total{mode="idle"}[5m])) * 100) > 90
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: 'Host {{ `{{ `$labels.instance `}}` }} CPU > 90% for 5 min'

      - alert: ContainerOOMRestart
        expr: changes(container_last_seen[5m]) > 3
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: 'Container {{ `{{ `$labels.name `}}` }} restarted multiple times'
"@
$alertRulesYml | Out-File -Encoding utf8 -FilePath "$RepoRoot\config\prometheus\rules\alerts.yml" -NoNewline
Write-Ok "alerts.yml written"

# -----------------------------------------------------------------------------
# 4. Loki config (single-binary, filesystem-backed)
# -----------------------------------------------------------------------------
Write-Section "Writing Loki config"

$lokiYml = @"
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: 168h          # 7 days
  ingestion_rate_mb: 8
  ingestion_burst_size_mb: 16
  max_query_series: 5000
  reject_old_samples: true
  reject_old_samples_max_age: 168h

compactor:
  working_directory: /loki/compactor
  retention_enabled: true
  delete_request_store: filesystem

ruler:
  storage:
    type: local
    local:
      directory: /loki/rules
  rule_path: /tmp/loki/scratch
  ring:
    kvstore:
      store: inmemory
  enable_api: true
"@
$lokiYml | Out-File -Encoding utf8 -FilePath "$RepoRoot\config\loki\loki-config.yml" -NoNewline
Write-Ok "loki-config.yml written"

# -----------------------------------------------------------------------------
# 5. Promtail config (M3-local; same template deployed on M1/M2 too)
# -----------------------------------------------------------------------------
Write-Section "Writing Promtail config"

$promtailYml = @"
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: docker
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        refresh_interval: 15s
    relabel_configs:
      - source_labels: ['__meta_docker_container_name']
        regex: '/(.*)'
        target_label: container
      - source_labels: ['__meta_docker_container_log_stream']
        target_label: stream
      - source_labels: ['__meta_docker_container_label_com_docker_compose_service']
        target_label: service
      - target_label: host
        replacement: m3
"@
$promtailYml | Out-File -Encoding utf8 -FilePath "$RepoRoot\config\promtail\promtail-config.yml" -NoNewline
Write-Ok "promtail-config.yml written"

# -----------------------------------------------------------------------------
# 6. Alertmanager config (Discord)
# -----------------------------------------------------------------------------
Write-Section "Writing Alertmanager config"

if ($DiscordWebhookUrl) {
    $alertmanagerYml = @"
global:
  resolve_timeout: 5m

route:
  receiver: discord
  group_by: ['alertname','severity']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: discord
    webhook_configs:
      - url: '$DiscordWebhookUrl/slack'
        send_resolved: true

inhibit_rules:
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname','instance']
"@
} else {
    $alertmanagerYml = @"
global:
  resolve_timeout: 5m

route:
  receiver: 'null'

receivers:
  - name: 'null'
"@
}
$alertmanagerYml | Out-File -Encoding utf8 -FilePath "$RepoRoot\config\alertmanager\alertmanager.yml" -NoNewline
Write-Ok "alertmanager.yml written ($(if($DiscordWebhookUrl){'Discord configured'}else{'no notifications'}))"

# -----------------------------------------------------------------------------
# 7. Grafana provisioning (datasources + dashboard loader)
# -----------------------------------------------------------------------------
Write-Section "Writing Grafana provisioning"

@"
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    editable: true
"@ | Out-File -Encoding utf8 -FilePath "$RepoRoot\config\grafana\provisioning\datasources\datasources.yml" -NoNewline

@"
apiVersion: 1
providers:
  - name: 'default'
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
"@ | Out-File -Encoding utf8 -FilePath "$RepoRoot\config\grafana\provisioning\dashboards\dashboards.yml" -NoNewline

Write-Ok "Grafana datasources + dashboard loader written"
Write-Warn2 "Drop community dashboard JSONs into $RepoRoot\config\grafana\dashboards\ — they'll auto-load."
Write-Warn2 "  Recommended IDs to import via Grafana UI: 1860 (Node Exp Full), 893 (cAdvisor), 13639 (Loki logs)"

# -----------------------------------------------------------------------------
# 8. docker-compose/observability.yml
# -----------------------------------------------------------------------------
Write-Section "Writing observability.yml"

$composeYml = @"
# =============================================================================
# AI-SOC Phase 4 — Observability Stack (M3)
# Generated by scripts/setup-m3.ps1
# =============================================================================

services:

  # ---------------------------------------------------------------------------
  # Prometheus — metrics scraper
  # ---------------------------------------------------------------------------
  prometheus:
    image: prom/prometheus:v2.55.1
    container_name: obs-prometheus
    hostname: prometheus
    restart: unless-stopped
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=15d'
      - '--web.enable-lifecycle'
      - '--web.enable-admin-api'
    volumes:
      - ../config/prometheus:/etc/prometheus:ro
      - ../data/prometheus:/prometheus
    ports:
      - "9090:9090"
    networks:
      - obs-net
    deploy:
      resources:
        limits:
          memory: 1500M
          cpus: '1.0'

  # ---------------------------------------------------------------------------
  # Grafana — dashboards
  # ---------------------------------------------------------------------------
  grafana:
    image: grafana/grafana:11.3.0
    container_name: obs-grafana
    hostname: grafana
    restart: unless-stopped
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=AiSocGrafana2026!
      - GF_INSTALL_PLUGINS=grafana-piechart-panel,grafana-clock-panel
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_AUTH_ANONYMOUS_ENABLED=false
      - GF_SERVER_ROOT_URL=http://$($M3_IP):3000
    volumes:
      - ../config/grafana/provisioning:/etc/grafana/provisioning:ro
      - ../config/grafana/dashboards:/var/lib/grafana/dashboards:ro
      - ../data/grafana:/var/lib/grafana
    ports:
      - "3000:3000"
    depends_on:
      - prometheus
      - loki
    networks:
      - obs-net
    deploy:
      resources:
        limits:
          memory: 512M

  # ---------------------------------------------------------------------------
  # Loki — log aggregation
  # ---------------------------------------------------------------------------
  loki:
    image: grafana/loki:3.2.1
    container_name: obs-loki
    hostname: loki
    restart: unless-stopped
    command: -config.file=/etc/loki/loki-config.yml
    volumes:
      - ../config/loki/loki-config.yml:/etc/loki/loki-config.yml:ro
      - ../data/loki:/loki
    ports:
      - "3100:3100"
    networks:
      - obs-net
    deploy:
      resources:
        limits:
          memory: 1024M

  # ---------------------------------------------------------------------------
  # Promtail — ships M3's Docker logs to Loki
  # ---------------------------------------------------------------------------
  promtail:
    image: grafana/promtail:3.2.1
    container_name: obs-promtail
    hostname: promtail
    restart: unless-stopped
    command: -config.file=/etc/promtail/promtail-config.yml
    volumes:
      - ../config/promtail/promtail-config.yml:/etc/promtail/promtail-config.yml:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
    depends_on:
      - loki
    networks:
      - obs-net
    deploy:
      resources:
        limits:
          memory: 256M

  # ---------------------------------------------------------------------------
  # Alertmanager — routes Prometheus alerts to Discord
  # ---------------------------------------------------------------------------
  alertmanager:
    image: prom/alertmanager:v0.27.0
    container_name: obs-alertmanager
    hostname: alertmanager
    restart: unless-stopped
    command:
      - '--config.file=/etc/alertmanager/alertmanager.yml'
      - '--storage.path=/alertmanager'
    volumes:
      - ../config/alertmanager:/etc/alertmanager:ro
      - ../data/alertmanager:/alertmanager
    ports:
      - "9093:9093"
    networks:
      - obs-net
    deploy:
      resources:
        limits:
          memory: 256M

  # ---------------------------------------------------------------------------
  # cAdvisor — per-container resource metrics (M3-local)
  # ---------------------------------------------------------------------------
  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    container_name: obs-cadvisor
    hostname: cadvisor
    restart: unless-stopped
    privileged: true
    devices:
      - /dev/kmsg
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker:/var/lib/docker:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    ports:
      - "8081:8080"
    networks:
      - obs-net
    deploy:
      resources:
        limits:
          memory: 384M

networks:
  obs-net:
    driver: bridge
"@
$composeYml | Out-File -Encoding utf8 -FilePath "$RepoRoot\docker-compose\observability.yml" -NoNewline
Write-Ok "observability.yml written"

# -----------------------------------------------------------------------------
# 9. Pre-pull images
# -----------------------------------------------------------------------------
if (-not $SkipImagePull) {
    Write-Section "Pre-pulling Docker images (~3 GB total, ~5-10 min on first run)"
    $images = @(
        "prom/prometheus:v2.55.1",
        "grafana/grafana:11.3.0",
        "grafana/loki:3.2.1",
        "grafana/promtail:3.2.1",
        "prom/alertmanager:v0.27.0",
        "gcr.io/cadvisor/cadvisor:v0.49.1"
    )
    foreach ($img in $images) {
        Write-Host "  pulling $img ..." -NoNewline
        docker pull $img | Out-Null
        Write-Host " done" -ForegroundColor Green
    }
} else {
    Write-Warn2 "Skipped image pull (-SkipImagePull). Run 'docker compose pull' before first start."
}

# -----------------------------------------------------------------------------
# 10. Done — print next steps
# -----------------------------------------------------------------------------
Write-Section "Setup complete"

Write-Host @"

NEXT STEPS (manual — none of these are auto-run for safety):

1. Install windows_exporter on M1, M2, AND M3 (host metrics for Prometheus):
     winget install --id=prometheus-community.windows_exporter -e
   or download MSI from https://github.com/prometheus-community/windows_exporter/releases
   Default port 9182 is what prometheus.yml expects.

2. Open firewall ports on M1, M2, M3 (PowerShell as Admin):
     New-NetFirewallRule -DisplayName 'Prom windows_exporter' -Direction Inbound -Protocol TCP -LocalPort 9182 -Action Allow
     New-NetFirewallRule -DisplayName 'cAdvisor'              -Direction Inbound -Protocol TCP -LocalPort 8081 -Action Allow

3. Add cAdvisor + Promtail to M1 and M2 stacks (so logs/metrics reach M3):
     (this script only sets them up locally on M3 — the M1/M2 compose files
      need a small additional service block, do later)

4. Bring the M3 stack up:
     cd $RepoRoot\docker-compose
     docker compose -f observability.yml up -d

5. First-time UI access:
     Grafana       http://$($M3_IP):3000   (admin / AiSocGrafana2026!)
     Prometheus    http://$($M3_IP):9090
     Alertmanager  http://$($M3_IP):9093
     Loki API      http://$($M3_IP):3100/ready

6. In Grafana UI, import community dashboards:
     1860  — Node Exporter Full
     14694 — Windows Exporter
     893   — Docker Containers (cAdvisor)
     13639 — Logs / Loki

7. Build the custom Command Center dashboard (the portfolio differentiator)
   on top of the data flowing in — that is your last differentiated piece.

8. Optional but recommended: install Wazuh Agent on M3 so it shows in SIEM:
     download MSI from https://packages.wazuh.com/4.x/windows/
     manager IP: $WazuhManagerIP

"@ -ForegroundColor Cyan

Write-Ok "Done. Files written under $RepoRoot"

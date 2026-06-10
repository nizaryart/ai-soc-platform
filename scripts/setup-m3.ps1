# =============================================================================
# AI-SOC - Machine 3 (Observability Stack) Setup
# =============================================================================
# ASCII-only version. Bootstraps the full M3 observability stack:
#   Prometheus + Grafana + Loki + Promtail + AlertManager + cAdvisor
#
# Run from M3 in an elevated PowerShell.
# =============================================================================

[CmdletBinding()]
param(
    [string]$RepoRoot          = "C:\AI_Soc_P\ai-soc-portfolio",
    [string]$M1_IP             = "192.168.100.124",
    [string]$M2_IP             = "192.168.100.152",
    [string]$M3_IP             = "",
    [string]$WazuhManagerIP    = "",
    [string]$DiscordWebhookUrl = "",
    [switch]$SkipImagePull
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

function Write-Section($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Ok($msg)      { Write-Host "  [OK]  $msg" -ForegroundColor Green }
function Write-Warn2($msg)   { Write-Host "  [!!]  $msg" -ForegroundColor Yellow }
function Write-Err2($msg)    { Write-Host "  [XX]  $msg" -ForegroundColor Red }

# Helper: write text content as UTF-8 WITHOUT BOM (Docker/Linux tools dislike BOMs).
function Save-Utf8NoBom([string]$Path, [string]$Content) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

# -----------------------------------------------------------------------------
# 0. Prereq checks
# -----------------------------------------------------------------------------
Write-Section "Prerequisite checks"

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent() `
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) { Write-Ok "Running elevated" }
else          { Write-Warn2 "Not running as Administrator (some later steps may need it)" }

try {
    $dockerVer = (docker version --format '{{.Server.Version}}' 2>$null)
    if ([string]::IsNullOrEmpty($dockerVer)) { throw "no daemon" }
    Write-Ok "Docker engine reachable (server $dockerVer)"
} catch {
    Write-Err2 "Docker engine not reachable. Start Docker Desktop and re-run."
    exit 1
}

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
    if ($M3_IP) { Write-Ok "Auto-detected M3 IP: $M3_IP" }
    else        { $M3_IP = Read-Host "M3 IP address" }
}

if (-not $WazuhManagerIP)   { $WazuhManagerIP = $M1_IP }
if (-not $DiscordWebhookUrl){ $DiscordWebhookUrl = Read-Host "Discord webhook URL (blank to skip)" }

Write-Host ""
Write-Host "  M1_IP            = $M1_IP"
Write-Host "  M2_IP            = $M2_IP"
Write-Host "  M3_IP            = $M3_IP"
Write-Host "  WazuhManagerIP   = $WazuhManagerIP"
Write-Host "  Repo root        = $RepoRoot"
Write-Host "  Discord set      = $([bool]$DiscordWebhookUrl)"

# -----------------------------------------------------------------------------
# 2. Directory layout
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

$prometheusYml = @'
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
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: windows_exporter
    static_configs:
      - targets:
          - __M1__:9182
          - __M2__:9182
          - __M3__:9182
        labels:
          os: windows

  - job_name: cadvisor
    static_configs:
      - targets:
          - __M1__:8081
          - __M2__:8081
          - __M3__:8081

  - job_name: ai_services
    metrics_path: /metrics
    static_configs:
      - targets:
          - __M2__:8100
          - __M2__:8300
          - __M2__:8500
          - __M2__:8002

  - job_name: wazuh_indexer
    metrics_path: /
    static_configs:
      - targets: [__M1__:9200]

  - job_name: soar_health
    static_configs:
      - targets:
          - __M1__:9010
          - __M1__:9011
          - __M1__:3001
          - __M1__:5001
'@
$prometheusYml = $prometheusYml.Replace('__M1__', $M1_IP).Replace('__M2__', $M2_IP).Replace('__M3__', $M3_IP)
Save-Utf8NoBom -Path "$RepoRoot\config\prometheus\prometheus.yml" -Content $prometheusYml
Write-Ok "prometheus.yml written"

$alertRulesYml = @'
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
          summary: 'Scrape target down on {{ $labels.instance }}'

      - alert: HostHighMemory
        expr: 100 - (windows_os_physical_memory_free_bytes / windows_cs_physical_memory_bytes * 100) > 92
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: 'Memory > 92% on {{ $labels.instance }}'

      - alert: HostHighCpu
        expr: 100 - (avg by (instance) (rate(windows_cpu_time_total{mode="idle"}[5m])) * 100) > 90
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: 'CPU > 90% on {{ $labels.instance }}'

      - alert: ContainerOOMRestart
        expr: changes(container_last_seen[5m]) > 3
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: 'Container {{ $labels.name }} restarted repeatedly'
'@
Save-Utf8NoBom -Path "$RepoRoot\config\prometheus\rules\alerts.yml" -Content $alertRulesYml
Write-Ok "alerts.yml written"

# -----------------------------------------------------------------------------
# 4. Loki config
# -----------------------------------------------------------------------------
Write-Section "Writing Loki config"

$lokiYml = @'
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
  retention_period: 168h
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
'@
Save-Utf8NoBom -Path "$RepoRoot\config\loki\loki-config.yml" -Content $lokiYml
Write-Ok "loki-config.yml written"

# -----------------------------------------------------------------------------
# 5. Promtail config
# -----------------------------------------------------------------------------
Write-Section "Writing Promtail config"

$promtailYml = @'
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
'@
Save-Utf8NoBom -Path "$RepoRoot\config\promtail\promtail-config.yml" -Content $promtailYml
Write-Ok "promtail-config.yml written"

# -----------------------------------------------------------------------------
# 6. Alertmanager config
# -----------------------------------------------------------------------------
Write-Section "Writing Alertmanager config"

if ($DiscordWebhookUrl) {
    $alertmanagerYml = @'
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
      - url: '__DISCORD_URL__/slack'
        send_resolved: true

inhibit_rules:
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname','instance']
'@
    $alertmanagerYml = $alertmanagerYml.Replace('__DISCORD_URL__', $DiscordWebhookUrl)
} else {
    $alertmanagerYml = @'
global:
  resolve_timeout: 5m

route:
  receiver: 'null'

receivers:
  - name: 'null'
'@
}
Save-Utf8NoBom -Path "$RepoRoot\config\alertmanager\alertmanager.yml" -Content $alertmanagerYml
Write-Ok ("alertmanager.yml written ({0})" -f $(if($DiscordWebhookUrl){"Discord configured"}else{"no notifications"}))

# -----------------------------------------------------------------------------
# 7. Grafana provisioning
# -----------------------------------------------------------------------------
Write-Section "Writing Grafana provisioning"

$grafanaDs = @'
apiVersion: 1
datasources:
  # Explicit `uid:` is critical - dashboards from grafana.com bake the UID
  # into every panel. If Grafana auto-generates UIDs, dashboards point at
  # non-existent datasources and silently show "No data" everywhere.
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
  - name: Loki
    uid: loki
    type: loki
    access: proxy
    url: http://loki:3100
    editable: true
'@
Save-Utf8NoBom -Path "$RepoRoot\config\grafana\provisioning\datasources\datasources.yml" -Content $grafanaDs

$grafanaDashLoader = @'
apiVersion: 1
providers:
  - name: 'default'
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
'@
Save-Utf8NoBom -Path "$RepoRoot\config\grafana\provisioning\dashboards\dashboards.yml" -Content $grafanaDashLoader

Write-Ok "Grafana datasources + dashboard loader written"
Write-Warn2 "Drop community dashboard JSONs into $RepoRoot\config\grafana\dashboards\ - they will auto-load."
Write-Warn2 "  Suggested Grafana dashboards: 1860, 14694 (windows_exporter), 893 (cAdvisor), 13639 (Loki logs)"

# -----------------------------------------------------------------------------
# 8. observability.yml
# -----------------------------------------------------------------------------
Write-Section "Writing observability.yml"

$composeYml = @'
services:

  prometheus:
    image: prom/prometheus:v2.51.2
    container_name: obs-prometheus
    hostname: prometheus
    restart: unless-stopped
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--storage.tsdb.retention.time=15d"
      - "--web.enable-lifecycle"
      - "--web.enable-admin-api"
    volumes:
      - ../config/prometheus:/etc/prometheus:ro
      - prom-data:/prometheus
    ports:
      - "9090:9090"
    networks:
      - obs-net
    deploy:
      resources:
        limits:
          memory: 1500M
          cpus: "1.0"

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
      - GF_SERVER_ROOT_URL=http://__M3__:3000
    volumes:
      - ../config/grafana/provisioning:/etc/grafana/provisioning:ro
      - ../config/grafana/dashboards:/var/lib/grafana/dashboards:ro
      - grafana-data:/var/lib/grafana
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

  loki:
    image: grafana/loki:3.2.1
    container_name: obs-loki
    hostname: loki
    restart: unless-stopped
    command: -config.file=/etc/loki/loki-config.yml
    volumes:
      - ../config/loki/loki-config.yml:/etc/loki/loki-config.yml:ro
      - loki-data:/loki
    ports:
      - "3100:3100"
    networks:
      - obs-net
    deploy:
      resources:
        limits:
          memory: 1024M

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

  alertmanager:
    image: prom/alertmanager:v0.27.0
    container_name: obs-alertmanager
    hostname: alertmanager
    restart: unless-stopped
    command:
      - "--config.file=/etc/alertmanager/alertmanager.yml"
      - "--storage.path=/alertmanager"
    volumes:
      - ../config/alertmanager:/etc/alertmanager:ro
      - alertmanager-data:/alertmanager
    ports:
      - "9093:9093"
    networks:
      - obs-net
    deploy:
      resources:
        limits:
          memory: 256M

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

volumes:
  prom-data: {}
  grafana-data: {}
  loki-data: {}
  alertmanager-data: {}
'@
$composeYml = $composeYml.Replace('__M3__', $M3_IP)
Save-Utf8NoBom -Path "$RepoRoot\docker-compose\observability.yml" -Content $composeYml
Write-Ok "observability.yml written"

# -----------------------------------------------------------------------------
# 9. Pre-pull images
# -----------------------------------------------------------------------------
if (-not $SkipImagePull) {
    Write-Section "Pre-pulling Docker images (~3 GB total)"
    $images = @(
        "prom/prometheus:v2.51.2",
        "grafana/grafana:11.3.0",
        "grafana/loki:3.2.1",
        "grafana/promtail:3.2.1",
        "prom/alertmanager:v0.27.0",
        "gcr.io/cadvisor/cadvisor:v0.49.1"
    )
    foreach ($img in $images) {
        Write-Host ("  pulling {0} ..." -f $img) -NoNewline
        docker pull $img | Out-Null
        Write-Host " done" -ForegroundColor Green
    }
} else {
    Write-Warn2 "Skipped image pull (-SkipImagePull)."
}

# -----------------------------------------------------------------------------
# 10. Next-steps printout
# -----------------------------------------------------------------------------
Write-Section "Setup complete"

$next = @"

NEXT STEPS (manual):

1. Install windows_exporter on M1, M2 AND M3 (for host metrics):
     winget install --id=prometheus-community.windows_exporter -e
   Default port 9182 is what prometheus.yml expects.

2. Open firewall ports on M1, M2, M3 (PowerShell as Admin):
     New-NetFirewallRule -DisplayName 'Prom windows_exporter' -Direction Inbound -Protocol TCP -LocalPort 9182 -Action Allow
     New-NetFirewallRule -DisplayName 'cAdvisor'              -Direction Inbound -Protocol TCP -LocalPort 8081 -Action Allow

3. Bring the M3 stack up:
     cd $RepoRoot\docker-compose
     docker compose -f observability.yml up -d

4. First-time UI access:
     Grafana       http://${M3_IP}:3000   (admin / AiSocGrafana2026!)
     Prometheus    http://${M3_IP}:9090
     Alertmanager  http://${M3_IP}:9093
     Loki API      http://${M3_IP}:3100/ready

5. In Grafana UI, import community dashboards by ID:
     14694  Windows Exporter
     893    Docker (cAdvisor)
     13639  Logs / Loki

6. Install Wazuh Agent on M3 (manager IP $WazuhManagerIP):
     download MSI from https://packages.wazuh.com/4.x/windows/

"@
Write-Host $next -ForegroundColor Cyan
Write-Ok "Done. Files written under $RepoRoot"

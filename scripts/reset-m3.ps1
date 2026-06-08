# =============================================================================
# AI-SOC - Machine 3 Full Reset + Verify
# =============================================================================
# Tears the M3 observability stack down completely, wipes all state
# (volumes + data dirs), regenerates configs via setup-m3.ps1, brings
# everything back up, and verifies each service is healthy.
#
# Use when M3's stack is in a broken state and you want a clean slate.
#
# Run from M3 in an elevated PowerShell.
# =============================================================================

[CmdletBinding()]
param(
    [string]$RepoRoot          = "C:\AI_Soc_P\ai-soc-portfolio",
    [string]$M3_IP             = "192.168.100.8",
    [string]$DiscordWebhookUrl = "",
    [switch]$KeepImages
)

$ErrorActionPreference = "Stop"

function Write-Section($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Ok($msg)      { Write-Host "  [OK]  $msg" -ForegroundColor Green }
function Write-Warn2($msg)   { Write-Host "  [!!]  $msg" -ForegroundColor Yellow }
function Write-Err2($msg)    { Write-Host "  [XX]  $msg" -ForegroundColor Red }

# -----------------------------------------------------------------------------
# 1. Tear down the stack
# -----------------------------------------------------------------------------
Write-Section "Tearing down M3 observability stack"

Push-Location $RepoRoot
try {
    docker compose -f docker-compose\observability.yml down --volumes --remove-orphans 2>&1 | Out-Host
    Write-Ok "Stack torn down (containers + named volumes removed)"
} catch {
    Write-Warn2 "compose down had errors (likely no stack was running) - continuing"
}
Pop-Location

# -----------------------------------------------------------------------------
# 2. Belt-and-suspenders: remove any lingering containers
# -----------------------------------------------------------------------------
Write-Section "Removing any lingering obs-* containers"

$containers = @("obs-prometheus","obs-grafana","obs-loki","obs-promtail","obs-alertmanager","obs-cadvisor")
foreach ($c in $containers) {
    $exists = docker ps -a --filter "name=^/$c$" --format "{{.Names}}" 2>$null
    if ($exists) {
        docker rm -f $c 2>&1 | Out-Null
        Write-Ok "removed $c"
    }
}

# -----------------------------------------------------------------------------
# 3. Wipe any old host-side data dirs (from earlier bind-mount setup)
# -----------------------------------------------------------------------------
Write-Section "Wiping old data directories"

$dataDirs = @(
    "$RepoRoot\data\prometheus",
    "$RepoRoot\data\grafana",
    "$RepoRoot\data\loki",
    "$RepoRoot\data\alertmanager"
)
foreach ($d in $dataDirs) {
    if (Test-Path $d) {
        Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue
        Write-Ok "removed $d"
    }
}

# -----------------------------------------------------------------------------
# 4. Remove the rogue grafana provisioning file if it exists
# -----------------------------------------------------------------------------
Write-Section "Cleaning rogue datasources files (if any)"

$rogueFile = "$RepoRoot\config\grafana\provisioning\datasources\prometheus.yml"
if (Test-Path $rogueFile) {
    Remove-Item -Force $rogueFile
    Write-Ok "removed leaked prometheus.yml from datasources/"
} else {
    Write-Ok "no rogue files (clean)"
}

# -----------------------------------------------------------------------------
# 5. Re-run setup-m3.ps1 (regenerates all configs, uses named volumes)
# -----------------------------------------------------------------------------
Write-Section "Regenerating configs via setup-m3.ps1"

$setupArgs = @(
    "-M3_IP", $M3_IP
)
if ($DiscordWebhookUrl) { $setupArgs += @("-DiscordWebhookUrl", $DiscordWebhookUrl) }
if ($KeepImages)        { $setupArgs += @("-SkipImagePull") }

& "$RepoRoot\scripts\setup-m3.ps1" @setupArgs

# -----------------------------------------------------------------------------
# 6. Bring the stack up
# -----------------------------------------------------------------------------
Write-Section "Bringing the stack up"

Push-Location $RepoRoot
docker compose -f docker-compose\observability.yml up -d 2>&1 | Out-Host
Pop-Location

# -----------------------------------------------------------------------------
# 7. Wait for services to settle, then verify each one
# -----------------------------------------------------------------------------
Write-Section "Waiting 30s for services to settle"
Start-Sleep -Seconds 30

Write-Section "Container state"
docker ps --filter "name=obs-" --format "table {{.Names}}`t{{.Status}}" | Out-Host

Write-Section "Local health checks"

$checks = @(
    @{ Name = "Prometheus";   Port = 9090; Path = "/-/healthy" },
    @{ Name = "Grafana";      Port = 3000; Path = "/api/health" },
    @{ Name = "AlertManager"; Port = 9093; Path = "/-/healthy" },
    @{ Name = "Loki";         Port = 3100; Path = "/ready" },
    @{ Name = "cAdvisor";     Port = 8081; Path = "/healthz" }
)

$allPass = $true
foreach ($c in $checks) {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$($c.Port)$($c.Path)" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($r.StatusCode -eq 200) {
            Write-Ok ("{0,-13} :{1} {2,-15} -> {3}" -f $c.Name, $c.Port, $c.Path, $r.StatusCode)
        } else {
            Write-Warn2 ("{0,-13} :{1} {2,-15} -> {3}" -f $c.Name, $c.Port, $c.Path, $r.StatusCode)
        }
    } catch {
        $allPass = $false
        $msg = $_.Exception.Message
        if ($msg.Length -gt 50) { $msg = $msg.Substring(0,50) + "..." }
        Write-Err2 ("{0,-13} :{1} {2,-15} -> FAIL: {3}" -f $c.Name, $c.Port, $c.Path, $msg)
    }
}

Write-Section "Restart counts (catch crash loops)"
foreach ($c in $containers) {
    $exists = docker ps -a --filter "name=^/$c$" --format "{{.Names}}" 2>$null
    if ($exists) {
        $rc = docker inspect $c --format '{{.RestartCount}}' 2>$null
        $st = docker inspect $c --format '{{.State.Status}}' 2>$null
        if ($rc -ge 3) {
            Write-Err2 ("{0,-25} restartCount={1,3}  status={2}  <-- crash loop" -f $c, $rc, $st)
        } else {
            Write-Ok ("{0,-25} restartCount={1,3}  status={2}" -f $c, $rc, $st)
        }
    }
}

Write-Section "Done"

if ($allPass) {
    Write-Host @"

ALL SERVICES HEALTHY ON M3.

Access URLs:
  Grafana       http://${M3_IP}:3000   (admin / AiSocGrafana2026!)
  Prometheus    http://${M3_IP}:9090
  AlertManager  http://${M3_IP}:9093
  Loki API      http://${M3_IP}:3100/ready

Next steps:
  - Open Grafana UI in browser
  - Import community dashboards: 14694, 893, 13639
"@ -ForegroundColor Green
} else {
    Write-Host @"

SOME SERVICES FAILED. To diagnose:
  docker logs obs-prometheus --tail 50
  docker logs obs-grafana    --tail 50
  docker logs obs-loki       --tail 50

Common issues:
  - Crash loop -> check the failing container's logs for config errors
  - Port already in use -> Get-NetTCPConnection -LocalPort <port>
  - Memory limit too low -> bump in docker-compose\observability.yml
"@ -ForegroundColor Yellow
}

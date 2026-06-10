# =============================================================================
# Fix Grafana dashboard JSONs for provisioning
# =============================================================================
# Grafana provisioning silently rejects dashboards that have:
#   - top-level "__inputs" / "__requires" / "__elements" keys (export-format only)
#   - "${DS_PROMETHEUS}" / "${DS_LOKI}" placeholder datasource variables
#
# This script:
#   1. Iterates every *.json in config/grafana/dashboards/
#   2. Removes the export wrapper keys
#   3. Substitutes datasource placeholders with the actual datasource names
#      (matching what we provisioned: "Prometheus" and "Loki")
#   4. Writes the cleaned JSON back
#
# Safe to re-run; idempotent.
# =============================================================================

[CmdletBinding()]
param(
    [string]$DashboardDir = "C:\AI_Soc_P\ai-soc-portfolio\config\grafana\dashboards"
)

$ErrorActionPreference = "Stop"

# Datasource UID substitutions (must match the `uid:` values in
# grafana/provisioning/datasources/datasources.yml — those are LOWERCASE
# `prometheus` and `loki` so dashboard panels resolve correctly).
$dsMap = @{
    '${DS_PROMETHEUS}'   = 'prometheus'
    '${DS_LOKI}'         = 'loki'
    '$${DS_PROMETHEUS}'  = 'prometheus'
    '$${DS_LOKI}'        = 'loki'
    '"Prometheus"'       = '"prometheus"'
    '"Loki"'             = '"loki"'
}

# Top-level keys to strip (grafana.com export wrapper)
$stripKeys = @('__inputs', '__requires', '__elements')

if (-not (Test-Path $DashboardDir)) {
    Write-Error "Dashboard dir not found: $DashboardDir"
    exit 1
}

$files = Get-ChildItem -Path $DashboardDir -Filter "*.json"
if (-not $files) {
    Write-Host "No dashboard JSONs found in $DashboardDir" -ForegroundColor Yellow
    exit 0
}

Write-Host "Processing $($files.Count) dashboard files in $DashboardDir`n" -ForegroundColor Cyan

$fixed = 0
$skipped = 0

foreach ($file in $files) {
    Write-Host "  $($file.Name)..." -NoNewline

    try {
        $raw = Get-Content $file.FullName -Raw -Encoding UTF8
        $json = $raw | ConvertFrom-Json
    } catch {
        Write-Host " ERROR (invalid JSON): $_" -ForegroundColor Red
        continue
    }

    $changed = $false

    # 1. Strip wrapper keys
    foreach ($k in $stripKeys) {
        if ($json.PSObject.Properties.Name -contains $k) {
            $json.PSObject.Properties.Remove($k)
            $changed = $true
        }
    }

    # 2. Substitute datasource placeholders in the JSON text (full-document search/replace)
    # Convert back to string, do text substitution, re-parse
    $text = $json | ConvertTo-Json -Depth 100 -Compress:$false
    foreach ($placeholder in $dsMap.Keys) {
        if ($text.Contains($placeholder)) {
            $text = $text.Replace($placeholder, $dsMap[$placeholder])
            $changed = $true
        }
    }

    if (-not $changed) {
        Write-Host " ok (already clean)" -ForegroundColor Gray
        $skipped++
        continue
    }

    # 3. Write back as UTF-8 without BOM (Grafana parses fine either way but consistency matters)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($file.FullName, $text, $utf8NoBom)

    Write-Host " fixed" -ForegroundColor Green
    $fixed++
}

Write-Host "`nDone. Fixed: $fixed | Already clean: $skipped" -ForegroundColor Cyan
Write-Host "Grafana auto-reloads every 30s. Verify with:" -ForegroundColor Cyan
Write-Host '  $auth = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:AiSocGrafana2026!"))'
Write-Host '  Invoke-RestMethod -Uri "http://localhost:3000/api/search" -Headers @{Authorization=$auth} | Format-Table id,title -AutoSize'

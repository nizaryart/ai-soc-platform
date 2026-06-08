# =============================================================================
# Prometheus diagnostic for M3 - run after git pull on M3
# Outputs structured blocks ready to paste back to chat.
# =============================================================================

[CmdletBinding()]
param(
    [switch]$SkipPull
)

$ErrorActionPreference = "Continue"

function Section($n) { Write-Host "`n========== $n ==========" -ForegroundColor Cyan }

# 1. Pull latest changes from origin
if (-not $SkipPull) {
    Section "git pull"
    Push-Location "C:\AI_Soc_P\ai-soc-portfolio"
    git pull
    Pop-Location
}

# 2. Test 1 - does the image even run --version
Section "TEST 1: docker run prometheus --version"
docker run --rm prom/prometheus:v2.51.2 --version 2>&1
Write-Host "EXIT_CODE=$LASTEXITCODE"

# 3. Test 2 - re-pull the image and retry
Section "TEST 2: re-pull image and rerun --version"
docker rmi prom/prometheus:v2.51.2 -f 2>&1 | Out-Null
docker pull prom/prometheus:v2.51.2 2>&1 | Select-Object -Last 5
Write-Host "---"
docker run --rm prom/prometheus:v2.51.2 --version 2>&1
Write-Host "EXIT_CODE=$LASTEXITCODE"

# 4. Test 3 - environment fingerprint
Section "TEST 3: environment fingerprint"

Write-Host "--- Docker info ---"
docker info 2>$null | Select-String -Pattern "Server Version|Operating System|Kernel|Architecture|CPUs|Total Memory"

Write-Host "`n--- WSL status ---"
wsl --status 2>&1
Write-Host "---"
wsl --list --verbose 2>&1

Write-Host "`n--- M3 CPU ---"
Get-WmiObject Win32_Processor | Select-Object Name, MaxClockSpeed, NumberOfCores, NumberOfLogicalProcessors | Format-List

Write-Host "--- M3 RAM ---"
Get-CimInstance Win32_OperatingSystem |
  Select-Object @{N='FreeRAM_GB';E={[math]::Round($_.FreePhysicalMemory/1MB,2)}},
                @{N='TotalRAM_GB';E={[math]::Round($_.TotalVisibleMemorySize/1MB,2)}} |
  Format-List

Write-Host "--- WSL2 VHD size ---"
Get-ChildItem "$env:LOCALAPPDATA\Docker\wsl" -Recurse -File -ErrorAction SilentlyContinue |
  Select-Object FullName, @{N='SizeGB';E={[math]::Round($_.Length/1GB,2)}} |
  Format-Table -AutoSize

Section "DONE - copy everything above and paste back to chat"

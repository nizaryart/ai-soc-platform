# ============================================================================
# AI-SOC — M2 Batch 4 Setup Script
# ============================================================================
# Run on Machine 2 ONLY (the AI Brain).
# Assumes you've completed Batch 1-3 manually:
#   - Docker Desktop installed + .wslconfig applied
#   - Ollama installed + listening on 0.0.0.0:11434
#   - Both Ollama models pulled (llama3.1:8b-instruct-q4_K_M + nomic-embed-text)
#   - Python 3.11+ and Git installed
#   - Portfolio repo cloned to C:\AI_oc_P\ai-soc-portfolio
#
# What this script does:
#   1. Sanity-checks prerequisites
#   2. Clones the OnyxLab upstream repo (skip if already present)
#   3. Copies ai-services.yml + services/ + models/ into the portfolio repo
#   4. Places the 6 pretrained .pkl models inside services/ml-inference/models/
#   5. Normalizes CRLF -> LF on all config and source files (Linux-side parsers
#      hate CRLF, same gotcha as Day 1)
#   6. Pre-pulls the dependency images (chromadb + postgres) in foreground
#
# Run:    .\scripts\m2-batch4-setup.ps1
# Or:     powershell -ExecutionPolicy Bypass -File .\scripts\m2-batch4-setup.ps1
# ============================================================================

$ErrorActionPreference = "Stop"

# ---------- helpers ----------
function Write-Section($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)      { Write-Host "    [OK]   $msg" -ForegroundColor Green }
function Write-Skip($msg)    { Write-Host "    [SKIP] $msg" -ForegroundColor Yellow }
function Write-Warn($msg)    { Write-Host "    [WARN] $msg" -ForegroundColor Yellow }
function Fail($msg)          { Write-Host ""; Write-Host "[FAIL] $msg" -ForegroundColor Red; exit 1 }

$ROOT     = "C:\AI_oc_P"
$PORTFOLIO= Join-Path $ROOT "ai-soc-portfolio"
$UPSTREAM = Join-Path $ROOT "ai-soc-upstream"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  AI-SOC  -  M2 Batch 4 Setup" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# ----------------------------------------------------------------------------
# Step 1 - Prerequisite checks
# ----------------------------------------------------------------------------
Write-Section "Step 1 / 6 - Prerequisite checks"

if (-not (Test-Path $ROOT))      { Fail "Working directory $ROOT does not exist. Did you do Batch 1-3?" }
if (-not (Test-Path $PORTFOLIO)) { Fail "Portfolio repo not found at $PORTFOLIO. Run: git clone https://github.com/nizaryart/ai-soc-platform.git $PORTFOLIO" }

foreach ($tool in @("git", "docker", "python")) {
    try {
        $null = Get-Command $tool -ErrorAction Stop
        Write-Ok "$tool found"
    } catch {
        # python may be installed as 'py' on Windows
        if ($tool -eq "python") {
            try { $null = Get-Command py -ErrorAction Stop; Write-Ok "python (via 'py' launcher) found" }
            catch { Fail "$tool not found in PATH" }
        } else {
            Fail "$tool not found in PATH"
        }
    }
}

# Docker daemon reachable?
# Use docker version which only fails on real daemon issues; stderr is silenced
# so PowerShell doesn't treat docker info's harmless WARNING lines as errors.
$null = docker version --format '{{.Server.Version}}' 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Ok "Docker daemon is responding"
} else {
    Fail "Docker daemon not responding. Is Docker Desktop running and fully started (green whale icon)?"
}

# Ollama listening on 0.0.0.0?
$ollamaBind = netstat -ano | Select-String ":11434.*LISTENING" | Select-String "0\.0\.0\.0"
if ($ollamaBind) { Write-Ok "Ollama listening on 0.0.0.0:11434 (LAN-accessible)" }
else { Write-Warn "Ollama not listening on 0.0.0.0:11434. Containers may not be able to reach it via host.docker.internal." }

# Models pulled?
$models = ollama list 2>$null
if ($models -match "llama3.1:8b-instruct-q4_K_M") { Write-Ok "Llama 3.1 8B model pulled" }
else { Write-Warn "Llama 3.1 8B not yet pulled. Phase 3 services will start but LLM calls will fail until 'ollama pull llama3.1:8b-instruct-q4_K_M' completes." }
if ($models -match "nomic-embed-text") { Write-Ok "nomic-embed-text model pulled" }
else { Write-Warn "nomic-embed-text not yet pulled. RAG ingest will fail until 'ollama pull nomic-embed-text' completes." }

# ----------------------------------------------------------------------------
# Step 2 - Clone OnyxLab upstream (or skip if present)
# ----------------------------------------------------------------------------
Write-Section "Step 2 / 6 - Clone OnyxLab upstream repo"

if (Test-Path $UPSTREAM) {
    Write-Skip "Upstream already exists at $UPSTREAM"
} else {
    git clone https://github.com/zhadyz/AI_SOC.git $UPSTREAM
    if ($LASTEXITCODE -ne 0) { Fail "git clone failed" }
    Write-Ok "Cloned to $UPSTREAM"
}

# Verify expected upstream content
$expected = @(
    "$UPSTREAM\docker-compose\ai-services.yml",
    "$UPSTREAM\services",
    "$UPSTREAM\models"
)
foreach ($p in $expected) {
    if (-not (Test-Path $p)) { Fail "Expected upstream path missing: $p" }
}
Write-Ok "Upstream content verified"

# ----------------------------------------------------------------------------
# Step 3 - Copy AI-side assets into portfolio
# ----------------------------------------------------------------------------
Write-Section "Step 3 / 6 - Copy ai-services.yml, services/, models/ into portfolio"

# ai-services.yml
$dst = Join-Path $PORTFOLIO "docker-compose\ai-services.yml"
Copy-Item "$UPSTREAM\docker-compose\ai-services.yml" $dst -Force
Write-Ok "Copied ai-services.yml"

# services/ (recurse, overwrite)
$dst = Join-Path $PORTFOLIO "services"
Copy-Item -Recurse "$UPSTREAM\services" $dst -Force
$count = (Get-ChildItem $dst -Directory).Count
Write-Ok "Copied services/ ($count subfolders)"

# models/ (recurse, overwrite)
$dst = Join-Path $PORTFOLIO "models"
Copy-Item -Recurse "$UPSTREAM\models" $dst -Force
$count = (Get-ChildItem $dst -File -Filter *.pkl).Count
Write-Ok "Copied models/ ($count .pkl files)"

# ----------------------------------------------------------------------------
# Step 4 - Place .pkl models inside ml-inference/models/
# ----------------------------------------------------------------------------
Write-Section "Step 4 / 6 - Stage .pkl models into services\ml-inference\models\"

$mlModelDir = Join-Path $PORTFOLIO "services\ml-inference\models"
New-Item -ItemType Directory -Force -Path $mlModelDir | Out-Null
Copy-Item "$PORTFOLIO\models\*.pkl" $mlModelDir -Force
$count = (Get-ChildItem $mlModelDir -File -Filter *.pkl).Count
Write-Ok "Staged $count .pkl files into services\ml-inference\models\"

# ----------------------------------------------------------------------------
# Step 5 - Normalize CRLF -> LF on all relevant text files
# ----------------------------------------------------------------------------
Write-Section "Step 5 / 6 - Normalize CRLF to LF (Linux-side parsers hate CRLF)"

$pyScript = @"
from pathlib import Path
root = Path(r'$PORTFOLIO/services')
fixed = []
for f in root.rglob('*'):
    if f.is_file() and f.suffix in ('.py', '.yml', '.yaml', '.json', '.conf', '.txt', '.sh', '.cfg', '.ini'):
        try:
            data = f.read_bytes()
            if b'\r\n' in data:
                f.write_bytes(data.replace(b'\r\n', b'\n'))
                fixed.append(str(f.relative_to(root)))
        except Exception as e:
            pass

# Also normalize the new ai-services.yml
compose = Path(r'$PORTFOLIO/docker-compose/ai-services.yml')
if compose.exists():
    d = compose.read_bytes()
    if b'\r\n' in d:
        compose.write_bytes(d.replace(b'\r\n', b'\n'))
        fixed.append('docker-compose/ai-services.yml')

print(f'Normalized {len(fixed)} files')
for x in fixed[:15]: print(' ', x)
if len(fixed) > 15: print(f'  ... and {len(fixed)-15} more')
"@

$tmp = New-TemporaryFile
$pyScript | Set-Content -Path $tmp -Encoding UTF8
try {
    $pythonExe = if (Get-Command python -ErrorAction SilentlyContinue) { "python" } else { "py" }
    & $pythonExe $tmp
    if ($LASTEXITCODE -ne 0) { Fail "Python normalization script failed" }
    Write-Ok "Line ending normalization complete"
} finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
# Step 6 - Pre-pull dependency images (chromadb + postgres)
# ----------------------------------------------------------------------------
Write-Section "Step 6 / 6 - Pre-pull dependency images (this takes a few minutes)"
Write-Host "    Pulling chromadb (~600 MB) and postgres (~80 MB)..."
Write-Host "    (Skipping ollama/ollama image - using your native Ollama install instead)"
Write-Host ""

Push-Location $PORTFOLIO
try {
    docker compose -f docker-compose\ai-services.yml pull chromadb postgres 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "docker compose pull failed" }
} finally {
    Pop-Location
}
Write-Ok "Dependency images pulled"

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  BATCH 4 COMPLETE" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Files now in portfolio:"
Write-Host "  $PORTFOLIO\docker-compose\ai-services.yml"
Write-Host "  $PORTFOLIO\services\          (9 subfolders)"
Write-Host "  $PORTFOLIO\models\            (6 .pkl files)"
Write-Host "  $PORTFOLIO\services\ml-inference\models\   (6 .pkl files)"
Write-Host ""
Write-Host "Next step (Batch 5):" -ForegroundColor Yellow
Write-Host "  Create $PORTFOLIO\docker-compose\.env"
Write-Host "  with the env vars Claude provided (M1 IP, TheHive + Cortex API keys, etc.)"
Write-Host ""
Write-Host "Then Batch 6:" -ForegroundColor Yellow
Write-Host "  cd $PORTFOLIO"
Write-Host "  docker compose -f docker-compose\ai-services.yml build"
Write-Host "  docker compose -f docker-compose\ai-services.yml up -d"
Write-Host ""

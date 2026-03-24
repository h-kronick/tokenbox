# TokenBox Windows PowerShell Installer
# Sets up hook, creates directories, installs skill dependencies
# Run: powershell -ExecutionPolicy Bypass -File install.ps1

$ErrorActionPreference = "Stop"

$hookDir = Join-Path $env:USERPROFILE ".tokenbox\hooks"
$dataDir = Join-Path $env:APPDATA "TokenBox"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "=== TokenBox Installer ===" -ForegroundColor Cyan
Write-Host ""

# 1. Create directories
Write-Host "[1/4] Creating directories..."
New-Item -ItemType Directory -Force -Path $hookDir | Out-Null
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
Write-Host "  Created $hookDir"
Write-Host "  Created $dataDir"

# 2. Copy hook script
Write-Host "[2/4] Installing status relay hook..."
$hookSrc = Join-Path $scriptDir "..\hooks\status-relay.mjs"
if (-not (Test-Path $hookSrc)) {
    Write-Host "  ERROR: Cannot find hooks\status-relay.mjs relative to this script." -ForegroundColor Red
    Write-Host "  Expected at: $hookSrc" -ForegroundColor Red
    exit 1
}
$hookDest = Join-Path $hookDir "status-relay.mjs"
Copy-Item $hookSrc $hookDest -Force
Write-Host "  Installed $hookDest"

# 3. Install Node.js dependencies
Write-Host "[3/4] Installing Node.js dependencies..."
$nodeCheck = $null
try {
    $nodeCheck = & node -v 2>$null
} catch {}

if ($nodeCheck) {
    $nodeVersion = $nodeCheck -replace '^v', ''
    $major = [int]($nodeVersion.Split('.')[0])
    if ($major -lt 18) {
        Write-Host "  WARNING: Node.js >= 18 required, found v$nodeVersion" -ForegroundColor Yellow
    } else {
        Write-Host "  Node.js $nodeCheck detected"
    }
} else {
    Write-Host "  WARNING: Node.js not found. Please install Node.js >= 18." -ForegroundColor Yellow
}

$npmCheck = $null
try {
    $npmCheck = & npm -v 2>$null
} catch {}

if ($npmCheck) {
    $skillDir = Join-Path $scriptDir "..\..\skill"
    if (Test-Path (Join-Path $skillDir "package.json")) {
        Push-Location $skillDir
        try {
            & npm install --omit=dev
            Write-Host "  Dependencies installed"
        } catch {
            Write-Host "  WARNING: npm install failed. Run manually in skill/ directory." -ForegroundColor Yellow
        }
        Pop-Location
    } else {
        Write-Host "  Skipping skill deps (skill/package.json not found)"
    }
} else {
    Write-Host "  WARNING: npm not found. Skipping dependency install." -ForegroundColor Yellow
}

# 4. Print hook configuration snippet
Write-Host "[4/4] Hook configuration"
Write-Host ""
Write-Host "  Add the following to your ~/.claude/settings.json to enable real-time tracking:"
Write-Host ""
Write-Host '  {' -ForegroundColor Green
Write-Host '    "statusLine": {' -ForegroundColor Green
Write-Host '      "type": "command",' -ForegroundColor Green
Write-Host '      "command": "node ~/.tokenbox/hooks/status-relay.mjs"' -ForegroundColor Green
Write-Host '    }' -ForegroundColor Green
Write-Host '  }' -ForegroundColor Green
Write-Host ""
Write-Host "  NOTE: This script does NOT modify settings.json automatically."
Write-Host "  Please add the statusLine configuration manually or merge it with your existing settings."
Write-Host ""
Write-Host "=== TokenBox installed successfully ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "To verify the hook works, run:"
Write-Host "  echo '{""session_id"":""test"",""model"":{""id"":""claude-sonnet-4-6""},""cost"":{""total_cost_usd"":0},""context_window"":{""current_usage"":{""input_tokens"":0,""output_tokens"":0,""cache_creation_input_tokens"":0,""cache_read_input_tokens"":0}}}' | node `"$hookDest`""
Write-Host "  Get-Content `"$(Join-Path $dataDir 'live.json')`""

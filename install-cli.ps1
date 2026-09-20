# Mission Canvas CLI — Windows Install (PowerShell)
# Usage: irm https://missioncanvas.ai/install-cli.ps1 | iex

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "  +==========================================+" -ForegroundColor Cyan
Write-Host "  |   Mission Canvas CLI                     |" -ForegroundColor Cyan
Write-Host "  |   Governed AI from your terminal         |" -ForegroundColor Cyan
Write-Host "  +==========================================+" -ForegroundColor Cyan
Write-Host ""

# ── Preflight ─────────────────────────────────────────────────────────────

function Test-Command($cmd) {
    return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

# Check Python
if (-not (Test-Command "python")) {
    if (Test-Command "python3") {
        Set-Alias -Name python -Value python3 -Scope Script
    } else {
        Write-Host "  X Required: Python 3.11+ not found" -ForegroundColor Red
        Write-Host "    Install: https://python.org" -ForegroundColor Yellow
        exit 1
    }
}

$pyVer = python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null
$parts = $pyVer -split '\.'
if ([int]$parts[0] -lt 3 -or ([int]$parts[0] -eq 3 -and [int]$parts[1] -lt 11)) {
    Write-Host "  X Python 3.11+ required (found $pyVer)" -ForegroundColor Red
    exit 1
}
Write-Host "  OK Python $pyVer" -ForegroundColor Green

# Check git
if (-not (Test-Command "git")) {
    Write-Host "  X Required: git not found" -ForegroundColor Red
    Write-Host "    Install: https://git-scm.com" -ForegroundColor Yellow
    exit 1
}
Write-Host "  OK git" -ForegroundColor Green

# ── Install ───────────────────────────────────────────────────────────────

$installDir = if ($env:MC_INSTALL_DIR) { $env:MC_INSTALL_DIR } else { "$env:USERPROFILE\.mission-canvas\cli" }

if (Test-Path "$installDir\.git") {
    Write-Host "  -> Updating existing install..."
    Push-Location $installDir
    git pull --quiet 2>$null
    Pop-Location
} else {
    Write-Host "  X Installation failed. Please download manually from https://missioncanvas.ai" -ForegroundColor Red
    exit 1
}
Write-Host "  OK Source ready" -ForegroundColor Green

# ── Dependencies ──────────────────────────────────────────────────────────

Write-Host "  -> Installing dependencies..."
Push-Location $installDir

$deps = "pyyaml httpx cryptography"
try {
    python -m pip install --quiet $deps.Split(" ") 2>$null
    Write-Host "  OK Dependencies" -ForegroundColor Green
} catch {
    Write-Host "  X Dependency install failed" -ForegroundColor Red
    Write-Host "    Try: pip install pyyaml httpx cryptography" -ForegroundColor Yellow
    Pop-Location
    exit 1
}
Pop-Location

# ── mc on PATH ────────────────────────────────────────────────────────────

# Create mc.cmd wrapper
$mcCmd = "$installDir\mc.cmd"
@"
@echo off
python "%~dp0src\mc_cli.py" %*
"@ | Set-Content $mcCmd -Encoding ASCII

# Add to user PATH if not present
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$installDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$installDir;$userPath", "User")
    Write-Host ""
    Write-Host "  ! Added $installDir to PATH" -ForegroundColor Yellow
    Write-Host "    Restart your terminal for mc to be available globally" -ForegroundColor Yellow
    Write-Host ""
}

# ── Ollama (optional) ─────────────────────────────────────────────────────

if (Test-Command "ollama") {
    try {
        $tags = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 2 -ErrorAction Stop
        if ($tags.models.Count -gt 0) {
            Write-Host "  OK Ollama ready (local inference available)" -ForegroundColor Green
        } else {
            Write-Host "  -> Pulling local model (qwen2.5:3b)..."
            ollama pull qwen2.5:3b 2>$null
            Write-Host "  OK Local model ready" -ForegroundColor Green
        }
    } catch {
        Write-Host "  ! Ollama installed but not running. Start with: ollama serve" -ForegroundColor Yellow
    }
} else {
    Write-Host "  i Ollama not installed - mc will work but without local inference" -ForegroundColor Gray
    Write-Host "    Install: https://ollama.com/download" -ForegroundColor Gray
    Write-Host "    Then: ollama pull qwen2.5:3b" -ForegroundColor Gray
}

# ── Verify ────────────────────────────────────────────────────────────────

Write-Host ""
$ignition = python "$installDir\src\mc_cli.py" ignition 2>$null
if ($ignition -match "The car will go") {
    Write-Host "  OK mc ignition passed" -ForegroundColor Green
} else {
    Write-Host "  ! mc ignition had warnings (run 'mc ignition' for details)" -ForegroundColor Yellow
}

# ── Done ──────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  +==========================================+" -ForegroundColor Cyan
Write-Host "  |   CLI installed                          |" -ForegroundColor Cyan
Write-Host "  |                                          |" -ForegroundColor Cyan
Write-Host "  |   Get started:                           |" -ForegroundColor Cyan
Write-Host "  |     mc setup          # configure LLMs   |" -ForegroundColor Cyan
Write-Host "  |     mc run `"query`"    # ask anything     |" -ForegroundColor Cyan
Write-Host "  |     mc health         # system status    |" -ForegroundColor Cyan
Write-Host "  |                                          |" -ForegroundColor Cyan
Write-Host "  |   Docs: https://missioncanvas.ai/docs    |" -ForegroundColor Cyan
Write-Host "  +==========================================+" -ForegroundColor Cyan
Write-Host ""

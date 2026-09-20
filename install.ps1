# Mission Canvas — Windows Install (PowerShell)
# Usage: irm https://missioncanvas.ai/install.ps1 | iex

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║   Mission Canvas Installer (Windows)     ║" -ForegroundColor Cyan
Write-Host "  ║   Governed AI for professionals          ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Detect architecture
$arch = if ([Environment]::Is64BitOperatingSystem) { "x86_64" } else { "x86" }
Write-Host "  ✓ Detected: windows-$arch" -ForegroundColor Green

$installDir = "$env:USERPROFILE\.mission-canvas"

# Native launcher — reboot never requires a terminal after this.
# Ported from lingua-viva/learning-architecture install.ps1 (Gap 2b pattern).
function Install-NativeLauncher {
    $launchDir = "$env:USERPROFILE\.mission-canvas"
    New-Item -ItemType Directory -Force -Path $launchDir | Out-Null

    # Create a hidden launcher .bat that the shortcut will point to
    $batPath = "$launchDir\mc-launch.bat"
    @"
@echo off
setlocal
set PORT=7891
set HEALTH_URL=http://127.0.0.1:%PORT%/api/health
set UI_URL=http://127.0.0.1:%PORT%

:: Check if already running
curl -fsS --max-time 2 "%HEALTH_URL%" >nul 2>&1
if %ERRORLEVEL% equ 0 (
    start "" "%UI_URL%"
    exit /b 0
)

:: Start the server
if exist "$launchDir\mc.exe" (
    start "" /B "$launchDir\mc.exe" serve %PORT%
) else if exist "$launchDir\src\mc_cli.py" (
    start "" /B python "$launchDir\src\mc_cli.py" serve %PORT%
) else (
    echo Mission Canvas not found — try re-running the installer.
    pause
    exit /b 1
)

:: Poll until ready
set /a tries=0
:waitloop
if %tries% geq 30 goto timeout
timeout /t 1 /nobreak >nul
curl -fsS --max-time 2 "%HEALTH_URL%" >nul 2>&1
if %ERRORLEVEL% equ 0 goto ready
set /a tries+=1
goto waitloop

:ready
start "" "%UI_URL%"
exit /b 0

:timeout
echo Mission Canvas didn't start in time.
exit /b 1
"@ | Out-File -FilePath $batPath -Encoding ASCII

    # Create Desktop shortcut
    try {
        $shell = New-Object -ComObject WScript.Shell
        $desktop = $shell.SpecialFolders("Desktop")
        $lnk = $shell.CreateShortcut("$desktop\Mission Canvas.lnk")
        $lnk.TargetPath = $batPath
        $lnk.WorkingDirectory = $launchDir
        $lnk.Description = "Mission Canvas — Governed AI for professionals"
        $lnk.WindowStyle = 7  # minimized
        $lnk.Save()
        Write-Host "  ✓ Desktop shortcut created" -ForegroundColor Green
    } catch {
        Write-Host "  ⚠ Couldn't create desktop shortcut" -ForegroundColor Yellow
    }

    # Create Start Menu shortcut
    try {
        $startMenu = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
        $lnk2 = $shell.CreateShortcut("$startMenu\Mission Canvas.lnk")
        $lnk2.TargetPath = $batPath
        $lnk2.WorkingDirectory = $launchDir
        $lnk2.Description = "Mission Canvas — Governed AI for professionals"
        $lnk2.WindowStyle = 7
        $lnk2.Save()
        Write-Host "  ✓ Start Menu shortcut created (search 'Mission Canvas')" -ForegroundColor Green
    } catch {
        Write-Host "  ⚠ Couldn't create Start Menu shortcut" -ForegroundColor Yellow
    }
}

function Check-Ollama {
    try {
        ollama --version 2>&1 | Out-Null
        Write-Host "  ✓ Ollama detected" -ForegroundColor Green
        Write-Host "  → Suggestion: Run 'ollama pull qwen2.5:7b' to pull the required model." -ForegroundColor Yellow
    } catch {
        Write-Host "  ⚠ Ollama not found. Install from https://ollama.com" -ForegroundColor Yellow
    }
}

# ── Try binary install first ──
$binary = "mc-windows-${arch}.exe"

# Release resolution: desktop-app releases (tags desktop-v*) live in the same
# repo, so we resolve the newest CLI release (tag v*) from the release list
# and avoid desktop-v* tags.
$releasesApi = "https://api.github.com/repos/pretendhome/missioncanvas.ai/releases?per_page=20"
$cliTag = ""
try {
    $response = Invoke-RestMethod -Uri $releasesApi -UseBasicParsing -ErrorAction Stop
    foreach ($release in $response) {
        if ($release.tag_name -like "v*") {
            $cliTag = $release.tag_name
            break
        }
    }
} catch {}

if ($cliTag) {
    $url = "https://github.com/pretendhome/missioncanvas.ai/releases/download/$cliTag/$binary"
    Write-Host "  → Downloading Mission Canvas ($cliTag)..." -ForegroundColor Cyan
} else {
    $url = "https://github.com/pretendhome/missioncanvas.ai/releases/latest/download/$binary"
    Write-Host "  → Attempting binary download..." -ForegroundColor Cyan
}
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

$binarySuccess = $false
try {
    Invoke-WebRequest -Uri $url -OutFile "$installDir\mc.exe" -UseBasicParsing -ErrorAction Stop
    Write-Host "  ✓ Installed mc binary to $installDir\mc.exe" -ForegroundColor Green
    $binarySuccess = $true
} catch {
    Write-Host "  ⚠ Binary download failed or not available. Falling back to source install." -ForegroundColor Yellow
}

if ($binarySuccess) {
    # Add to PATH
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -notlike "*\.mission-canvas*") {
        [Environment]::SetEnvironmentVariable("Path", "$userPath;$installDir", "User")
        $env:Path = "$env:Path;$installDir"
        Write-Host "  ✓ Added to PATH" -ForegroundColor Green
    }
    
    # Set UTF-8 permanently
    [Environment]::SetEnvironmentVariable("PYTHONUTF8", "1", "User")
    
    Check-Ollama

    # Auto-start the web server. Launch `mc serve` directly (a detached, persistent
    # process) rather than `mc start` — a frozen onefile exe spawning ITSELF as a
    # child inherits the parent's PyInstaller temp dir and dies when the parent
    # exits. Start-Process launches an independent process that survives.
    Write-Host "  → Starting web server on http://localhost:7891 ..." -ForegroundColor Cyan
    try {
        Start-Process -FilePath "$installDir\mc.exe" -ArgumentList "serve", "7891" -WindowStyle Hidden -ErrorAction SilentlyContinue
    } catch {}

    # Give the server time to bind. The frozen binary extracts (~3-5s) and loads
    # the ontology/knowledge before binding, so poll up to ~30s.
    $up = $false
    foreach ($i in 1..30) {
        Start-Sleep -Seconds 1
        try {
            Invoke-WebRequest -Uri "http://127.0.0.1:7891/" -UseBasicParsing -TimeoutSec 2 | Out-Null
            $up = $true; break
        } catch {}
    }

    if ($up) {
        Write-Host "  ✓ Web UI is live" -ForegroundColor Green
        # Opening a URL needs a registered http:// handler. A machine without
        # one (CI runner, Server Core, a stripped install) throws here, and
        # with $ErrorActionPreference = "Stop" that killed the whole installer
        # AFTER claiming the web UI was live — no banner, no shortcuts, no
        # launcher. Convenience must never abort an otherwise-good install.
        try {
            Start-Process "http://localhost:7891" -ErrorAction Stop
        } catch {
            Write-Host "  → Open http://localhost:7891 in your browser" -ForegroundColor Cyan
        }
    } else {
        Write-Host "  ⚠ Web server didn't come up in time — start it later with 'mc start'" -ForegroundColor Yellow
    }

    # Open the interactive CLI in a NEW window (the current session is the iex pipe)
    Write-Host "  → Opening Mission Canvas shell..." -ForegroundColor Cyan
    try {
        Start-Process -FilePath "powershell" `
            -ArgumentList "-NoExit", "-Command", "& '$installDir\mc.exe' shell" `
            -ErrorAction SilentlyContinue
    } catch {}

    # Native launcher — reboot never requires a terminal after this
    Install-NativeLauncher

    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║   Installation complete!                 ║" -ForegroundColor Cyan
    Write-Host "  ╠══════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "  ║   Web UI:   http://localhost:7891         ║" -ForegroundColor Cyan
    Write-Host "  ║   CLI:      opened in a new window        ║" -ForegroundColor Cyan
    Write-Host "  ║   Relaunch: search "Mission Canvas"      ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

# ── Source fallback ──
Write-Host "  → Installing from source..." -ForegroundColor Cyan

# Check Python
try {
    $pyver = python --version 2>&1
    if ($pyver -match "3\.(1[1-9]|[2-9]\d)") {
        Write-Host "  Python: $pyver ✓" -ForegroundColor Green
    } else {
        Write-Host "  ERROR: Python 3.11+ required (found $pyver)" -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "  ERROR: Python not found. Install from https://python.org" -ForegroundColor Red
    exit 1
}

# Check Git
try {
    git --version | Out-Null
    Write-Host "  Git: ✓" -ForegroundColor Green
} catch {
    Write-Host "  ERROR: Git required. Install from https://git-scm.com" -ForegroundColor Red
    exit 1
}

# Clone or Update
if (-not (Test-Path "$installDir\.git")) {
    Write-Host "  ✗ Binary download failed. Please download manually from https://missioncanvas.ai" -ForegroundColor Red
    exit 1
} else {
    Write-Host "  → Updating existing clone..." -ForegroundColor Cyan
    Push-Location "$installDir"
    try { git pull --quiet } catch {}
    Pop-Location
}

# Install dependencies
Push-Location "$installDir"
Write-Host "Installing Python dependencies..." -ForegroundColor Cyan
pip install --quiet --break-system-packages -e ".[dev]" 2>$null
if ($LASTEXITCODE -ne 0) {
    pip install --quiet --break-system-packages pyyaml redis fastapi uvicorn websockets pytest httpx 2>$null
}

# Install Node dependencies (optional)
try {
    $nodever = node --version 2>&1
    Write-Host "  Node.js: $nodever ✓" -ForegroundColor Green
    if (Test-Path "runtime/package.json") {
        Set-Location runtime
        npm install --silent 2>$null
        Set-Location ..
    }
} catch {
    Write-Host "  Node.js: not found (optional)" -ForegroundColor Yellow
}

Check-Ollama

# Health check
Write-Host ""
Write-Host "Running health check..." -ForegroundColor Cyan
try {
    python src/mc_cli.py health
} catch {
    Write-Host "  (Run 'python src/mc_cli.py health' to verify)" -ForegroundColor Yellow
}

# Auto-start server (source mode)
Write-Host "  → Starting web server on http://localhost:7891 ..." -ForegroundColor Cyan
try {
    Start-Process -FilePath "python" -ArgumentList "src/api_server.py" -WindowStyle Hidden -ErrorAction SilentlyContinue
} catch {}

# Poll until ready, then open browser
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    try {
        Invoke-WebRequest -Uri "http://127.0.0.1:7891/" -UseBasicParsing -TimeoutSec 2 | Out-Null
        $ready = $true
        break
    } catch { Start-Sleep -Seconds 1 }
}
if ($ready) {
    Write-Host "  ✓ Web UI is live" -ForegroundColor Green
    # Same hazard as the binary path above — never let opening a browser abort
    # a completed install.
    try {
        Start-Process "http://localhost:7891" -ErrorAction Stop
    } catch {
        Write-Host "  → Open http://localhost:7891 in your browser" -ForegroundColor Cyan
    }
} else {
    Write-Host "  ⚠ Server didn't start in time — open http://localhost:7891 manually" -ForegroundColor Yellow
}

Pop-Location

# Native launcher — reboot never requires a terminal after this
Install-NativeLauncher

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║     Installation complete                ║" -ForegroundColor Cyan
Write-Host "  ╠══════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "  ║  Start:  cd $installDir                  ║" -ForegroundColor Cyan
Write-Host "  ║          python src/mc_cli.py shell      ║" -ForegroundColor Cyan
Write-Host "  ║  Web UI: http://localhost:7891            ║" -ForegroundColor Cyan
Write-Host "  ║  Relaunch: search "Mission Canvas"       ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

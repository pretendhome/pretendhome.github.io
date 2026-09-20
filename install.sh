#!/bin/sh
# Mission Canvas — One Command Install
# Usage: curl -fsSL https://missioncanvas.ai/install.sh | sh
# Tries binary first, falls back to source install if no release exists.
#
# docs/install.sh (served at missioncanvas.ai/install.sh — docs/ is the
# GitHub Pages root) is a byte-for-byte copy of this file. Edit here, then:
#   cp install.sh docs/install.sh
# tests/test_install_surface.py fails the build if the two drift.
set -e

INSTALL_START=$(date +%s)

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   Mission Canvas Installer               ║"
echo "  ║   Governed AI for professionals          ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# Detect OS and architecture
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$ARCH" in
  x86_64|amd64) ARCH="x86_64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *) echo "  ✗ Unsupported architecture: $ARCH"; exit 1 ;;
esac

case "$OS" in
  darwin) PLATFORM="darwin"; ARCH="arm64" ;;  # Single universal binary
  linux) PLATFORM="linux" ;;
  *) echo "  ✗ Unsupported OS: $OS"; exit 1 ;;
esac

echo "  ✓ Detected: ${PLATFORM}-${ARCH}"

# Directories are created where each path needs them — the failure messages
# below promise "Nothing was changed", and that has to stay literally true.

# Pull Ollama model if ollama command is installed
pull_ollama() {
  if ! command -v ollama >/dev/null 2>&1; then
    return
  fi
  # Check if daemon is running
  if ! curl -s http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    echo "  ⚠ Ollama installed but daemon not running."
    case "$OS" in
      darwin) echo "    → Open /Applications/Ollama.app first, then re-run install" ;;
      *)      echo "    → Run: ollama serve &" ;;
    esac
    return
  fi
  # Hardware-adaptive model selection: query MC server for tier if available,
  # otherwise fall back to safe CPU-viable default (qwen2.5:3b).
  MODEL="qwen2.5:3b"
  TIER=$(curl -s http://127.0.0.1:7891/api/ollama/status 2>/dev/null | grep -o '"hardware_tier":"[^"]*"' | head -1 | cut -d'"' -f4)
  case "$TIER" in
    strong_gpu) MODEL="qwen3:14b" ;;
    mid_gpu)    MODEL="qwen3:8b" ;;
    weak_gpu)   MODEL="qwen2.5:3b" ;;
    cpu_only)   MODEL="qwen2.5:3b" ;;
  esac
  # Check if chosen model (or any variant) is already present
  if curl -s http://127.0.0.1:11434/api/tags 2>/dev/null | grep -q "${MODEL%%:*}"; then
    echo "  ✓ $MODEL already available"
  else
    echo "  → Downloading your local model ($MODEL) — this takes a"
    echo "    few minutes the first time. The install itself is quick; this"
    echo "    download is the part that varies with your connection."
    ollama pull "$MODEL" || true
  fi
  mkdir -p "$HOME/.mission-canvas"
  python3 -c "import json, pathlib; p = pathlib.Path('$HOME/.mission-canvas/providers.json'); d = json.loads(p.read_text()) if p.exists() else {}; d['ollama_model'] = '$MODEL'; p.write_text(json.dumps(d, indent=2))" 2>/dev/null || true
}

# Native launcher so restarting after reboot never requires a terminal.
# Ported from lingua-viva/learning-architecture install.sh (Gap 2b pattern,
# proven in Still I Rise v1.0.0). Idempotent: checks port 7891 for an
# already-running Mission Canvas before starting a second instance.
install_native_launcher() {
  mkdir -p "${HOME}/.local/bin" "${HOME}/.mission-canvas"
  cat > "${HOME}/.local/bin/mc-launch" << 'LAUNCHEOF'
#!/bin/sh
# Mission Canvas — native launcher. Double-clickable via a desktop icon;
# never opens a terminal for the user. Checks whether port 7891 is already
# serving Mission Canvas before starting a second instance.
PORT=7891
HEALTH_URL="http://127.0.0.1:${PORT}/api/health"
UI_URL="http://127.0.0.1:${PORT}"
LOG="${HOME}/.mission-canvas/launch.log"
mkdir -p "${HOME}/.mission-canvas"

open_browser() {
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$UI_URL" >/dev/null 2>&1 &
  elif command -v open >/dev/null 2>&1; then open "$UI_URL" >/dev/null 2>&1 &
  fi
}

notify() {
  echo "$(date): $1" >> "$LOG"
  if command -v notify-send >/dev/null 2>&1; then notify-send "Mission Canvas" "$1" >/dev/null 2>&1 || true; fi
  if command -v osascript >/dev/null 2>&1; then osascript -e "display notification \"$1\" with title \"Mission Canvas\"" >/dev/null 2>&1 || true; fi
}

# Desktop AppImage fallback (Linux, DL-69/DL-70). AppImages need libfuse.so.2
# to self-mount; on FUSE-less machines they die with
# "dlopen(): error loading libfuse.so.2". Fallback: extract once with
# --appimage-extract, then launch (and on later runs reuse) squashfs-root/AppRun.
launch_appimage() {
  [ "$(uname -s)" = "Linux" ] || return 1
  EXTRACT_BASE="${HOME}/.mission-canvas/appimage"
  # Extracted on a previous FUSE-less run? Reuse it — no re-extract needed.
  if [ -x "${EXTRACT_BASE}/squashfs-root/AppRun" ]; then
    notify "Starting Mission Canvas (extracted AppImage)."
    "${EXTRACT_BASE}/squashfs-root/AppRun" >>"$LOG" 2>&1 &
    return 0
  fi
  APPIMG=""
  for c in "${HOME}/.mission-canvas/MissionCanvas.AppImage" \
           "${HOME}/Applications/MissionCanvas.AppImage" \
           "${HOME}/Downloads/MissionCanvas.AppImage" \
           "${HOME}/Downloads"/Mission*Canvas*.AppImage; do
    if [ -f "$c" ]; then APPIMG="$c"; break; fi
  done
  [ -n "$APPIMG" ] || return 1
  chmod +x "$APPIMG" 2>/dev/null || true
  # FUSE present? The AppImage can self-mount — run it directly.
  if ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2'; then
    notify "Starting Mission Canvas."
    "$APPIMG" >>"$LOG" 2>&1 &
    return 0
  fi
  # No FUSE — extract once, then launch the extracted AppRun.
  notify "FUSE not available — extracting the app (one-time step)."
  mkdir -p "$EXTRACT_BASE"
  ( cd "$EXTRACT_BASE" && "$APPIMG" --appimage-extract >>"$LOG" 2>&1 )
  if [ -x "${EXTRACT_BASE}/squashfs-root/AppRun" ]; then
    "${EXTRACT_BASE}/squashfs-root/AppRun" >>"$LOG" 2>&1 &
    return 0
  fi
  return 1
}

# Already running (ours)? Just open the browser — don't start a second server.
RESPONSE=$(curl -fsS --max-time 2 "$HEALTH_URL" 2>/dev/null || echo "")
if [ -n "$RESPONSE" ]; then
  case "$RESPONSE" in
    *'"healthy"'*|*'"status"'*)
      notify "Mission Canvas is already running — opening your browser."
      open_browser
      exit 0
      ;;
    *)
      notify "Port ${PORT} is in use by another program — close it and try again."
      exit 1
      ;;
  esac
fi

# Port occupied by something that doesn't speak our health check? Fail loudly.
if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  notify "Port ${PORT} is in use by another program — close it and try again."
  exit 1
fi

# Port is free — start the server.
if command -v mc >/dev/null 2>&1; then
  mc serve "$PORT" >/dev/null 2>&1 &
elif [ -f "${HOME}/.mission-canvas/src/mc_cli.py" ]; then
  ( cd "${HOME}/.mission-canvas" && python3 -m src.api_server "$PORT" >/dev/null 2>&1 & )
else
  # No CLI/web install — fall back to the desktop AppImage if one is present.
  # The desktop app serves its own window; no port-7891 health wait applies.
  if launch_appimage; then
    exit 0
  fi
  notify "Couldn't find the Mission Canvas install — try re-running the installer."
  exit 1
fi

i=0
while [ "$i" -lt 30 ]; do
  if curl -fsS --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then break; fi
  i=$((i + 1)); sleep 1
done

if [ "$i" -lt 30 ]; then
  open_browser
else
  notify "Mission Canvas didn't start in time — try again in a moment."
  exit 1
fi
LAUNCHEOF
  chmod +x "${HOME}/.local/bin/mc-launch"

  case "$OS" in
    linux)
      APPS_DIR="${HOME}/.local/share/applications"
      mkdir -p "$APPS_DIR"
      cat > "${APPS_DIR}/mission-canvas.desktop" << DESKTOPEOF
[Desktop Entry]
Type=Application
Name=Mission Canvas
Comment=Governed AI for professionals
Exec=${HOME}/.local/bin/mc-launch
Terminal=false
Categories=Office;Development;
DESKTOPEOF
      chmod +x "${APPS_DIR}/mission-canvas.desktop"
      echo "  ✓ Desktop launcher installed (search \"Mission Canvas\" in your app menu)"
      ;;
    darwin)
      APP_DIR="${HOME}/Applications/Mission Canvas.app"
      mkdir -p "${APP_DIR}/Contents/MacOS"
      cat > "${APP_DIR}/Contents/MacOS/mission-canvas" << 'APPEOF'
#!/bin/sh
exec "$HOME/.local/bin/mc-launch"
APPEOF
      chmod +x "${APP_DIR}/Contents/MacOS/mission-canvas"
      cat > "${APP_DIR}/Contents/Info.plist" << 'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mission Canvas</string>
  <key>CFBundleExecutable</key><string>mission-canvas</string>
  <key>CFBundleIdentifier</key><string>ai.missioncanvas.app</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.2</string>
</dict>
</plist>
PLISTEOF
      echo "  ✓ App installed to ~/Applications/Mission Canvas.app"
      ;;
  esac
}

# ── Try binary install first ──
# Release resolution: desktop-app releases (tags desktop-v*) live in the same
# repo, so "releases/latest" can point at a release whose assets this script
# can't use (MissionCanvas-Setup.exe etc. instead of mc-*). Resolve the newest
# CLI release (tag v*) from the release list; fall back to "latest" only when
# the release list itself is unreachable.
BINARY="mc-${PLATFORM}-${ARCH}"
RELEASES_API="https://api.github.com/repos/pretendhome/missioncanvas.ai/releases?per_page=20"
CLI_TAG=$(curl -fsSL "$RELEASES_API" 2>/dev/null \
  | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"v[0-9][^"]*"' \
  | head -1 \
  | sed 's/.*"\(v[0-9][^"]*\)"/\1/')
if [ -n "$CLI_TAG" ]; then
  URL="https://github.com/pretendhome/missioncanvas.ai/releases/download/${CLI_TAG}/${BINARY}"
  echo "  → Downloading Mission Canvas (${CLI_TAG})..."
else
  URL="https://github.com/pretendhome/missioncanvas.ai/releases/latest/download/${BINARY}"
  echo "  → Downloading Mission Canvas..."
fi
TMPFILE=$(mktemp)
if curl -fsSL "$URL" -o "$TMPFILE" 2>/dev/null && [ -s "$TMPFILE" ]; then
  chmod +x "$TMPFILE"
  INSTALL_DIR="${HOME}/.local/bin"
  mkdir -p "$INSTALL_DIR"
  mv "$TMPFILE" "$INSTALL_DIR/mc"
  echo "  ✓ Installed mc to $INSTALL_DIR/mc"
  
  pull_ollama

  # Persist Ollama as configured provider if detected
  if command -v ollama >/dev/null 2>&1 && curl -s http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    mkdir -p "$HOME/.mission-canvas/config"
    if [ ! -f "$HOME/.mission-canvas/config/providers.json" ]; then
      cat > "$HOME/.mission-canvas/config/providers.json" << PROVEOF
{
  "providers": {
    "ollama": {
      "model": "${MODEL:-qwen2.5:3b}",
      "verified": true
    }
  },
  "default_provider": "ollama"
}
PROVEOF
      chmod 600 "$HOME/.mission-canvas/config/providers.json"
      echo "  ✓ Connected to Ollama / ${MODEL:-qwen2.5:3b}"
    fi
  fi

  # Put mc on PATH — write to shell profile (like Homebrew/Ollama do)
  case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *)
      export PATH="$INSTALL_DIR:$PATH"
      SHELL_NAME=$(basename "$SHELL")
      case "$SHELL_NAME" in
        zsh)  RC_FILE="$HOME/.zshrc" ;;
        bash) RC_FILE="$HOME/.bashrc" ;;
        *)    RC_FILE="$HOME/.profile" ;;
      esac
      if [ -f "$RC_FILE" ] && ! grep -q '.local/bin' "$RC_FILE" 2>/dev/null; then
        echo '' >> "$RC_FILE"
        echo '# Mission Canvas' >> "$RC_FILE"
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$RC_FILE"
        echo "  ✓ Added PATH to $RC_FILE"
      elif [ ! -f "$RC_FILE" ]; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' > "$RC_FILE"
        echo "  ✓ Created $RC_FILE with PATH"
      else
        echo "  ✓ PATH already configured in $RC_FILE"
      fi
      ;;
  esac

  # Auto-start the web server. Launch `mc serve` DIRECTLY (not `mc start`) — a
  # frozen onefile that spawns itself inherits the parent's bundle dir and the
  # child dies when the parent exits. A backgrounded direct serve is independent.
  echo "  → Starting web server on http://localhost:7891 ..."
  "$INSTALL_DIR/mc" serve 7891 >/dev/null 2>&1 &

  # Poll until the server binds (frozen extract + ontology load), then open the UI
  i=0
  while [ "$i" -lt 30 ]; do
    if curl -fsS "http://127.0.0.1:7891/" >/dev/null 2>&1; then break; fi
    i=$((i + 1)); sleep 1
  done
  if [ "$i" -lt 30 ]; then
    echo "  ✓ Web UI is live"
    if command -v xdg-open >/dev/null 2>&1; then xdg-open "http://localhost:7891" >/dev/null 2>&1 &
    elif command -v open >/dev/null 2>&1; then open "http://localhost:7891" >/dev/null 2>&1 &
    fi
  else
    echo "  ⚠ Web server didn't come up in time — start it later with 'mc serve'"
  fi

  # Run health check — show actual result
  echo "  → Running health check..."
  if "$INSTALL_DIR/mc" health 2>&1 | grep -q "PASS\|Health:.*100"; then
    echo "  ✓ Health check passed"
  else
    echo "  ⚠ Health check incomplete (run 'mc health' in a new terminal)"
  fi

  # Native launcher — reboot never requires a terminal after this
  install_native_launcher

  # Install log summary — Duration makes the "2 minutes" promise measurable.
  # Ollama/Model are NOT logged here: on a cold install the wizard installs
  # Ollama AFTER this script exits. The wizard appends its own completion
  # line ("[wizard] ollama install: completed") when it finishes. Logging
  # Ollama status here produces "not found" on every cold install, which
  # misleads support engineers reading the log top-down.
  INSTALL_SECS=$(( $(date +%s) - INSTALL_START ))
  mkdir -p "$HOME/.mission-canvas"
  {
    echo "=== Install completed: $(date) ==="
    echo "OS: $(uname -a)"
    echo "Binary: $INSTALL_DIR/mc"
    echo "Release: ${CLI_TAG:-latest}"
    echo "Duration: ${INSTALL_SECS}s"
  } >> "$HOME/.mission-canvas/install.log"

  echo ""
  echo "  ✓ Ready in ${INSTALL_SECS} seconds"
  echo ""
  echo "  ╔══════════════════════════════════════════╗"
  echo "  ║   Installation complete!                 ║"
  echo "  ╠══════════════════════════════════════════╣"
  echo "  ║   Web UI:  http://localhost:7891          ║"
  echo "  ║   CLI:     mc shell (open new terminal)   ║"
  echo "  ║   Relaunch: search \"Mission Canvas\"      ║"
  echo "  ╚══════════════════════════════════════════╝"
  echo ""
  exit 0
fi
rm -f "$TMPFILE" 2>/dev/null

# ── Source install (fallback) ──
# The aspiration bar: nobody should have to know what Python or git are.
# Every message below says what happened and what to do next, in plain
# words — no requirement dumps, no stack traces.

# Blocked/offline internet must produce a plain answer, not a git error dump.
if ! curl -fsS --max-time 10 "https://github.com" >/dev/null 2>&1; then
  echo ""
  echo "  ✗ It looks like this computer can't reach the internet right now"
  echo "    (or github.com is blocked on this network). Nothing was changed."
  echo "    → Check your connection, then run the same install command again."
  exit 1
fi

echo "  ⚠ The quick download isn't available right now — setting up the full"
echo "    version instead. Still automatic; it just takes a few minutes longer."

# Check Python
if ! python3 -c 'import sys; exit(0 if sys.version_info >= (3,11) else 1)' 2>/dev/null; then
  echo ""
  echo "  ✗ This computer is missing a tool the full setup needs (Python 3.11"
  echo "    or newer). Nothing was changed. Two easy ways forward:"
  echo "    → Get the ready-to-run app at https://missioncanvas.ai"
  echo "    → Or install Python from https://python.org, then run this same"
  echo "      install command again."
  exit 1
fi
echo "  ✓ Python $(python3 --version 2>&1 | cut -d' ' -f2)"

# Check Git
if ! git --version >/dev/null 2>&1; then
  echo ""
  echo "  ✗ This computer is missing a tool the full setup needs (git)."
  echo "    Nothing was changed."
  echo "    → Install it from https://git-scm.com/downloads, then run this"
  echo "      same install command again."
  exit 1
fi
echo "  ✓ Git"

# Clone or update to ~/.mission-canvas/
INSTALL_DIR="${HOME}/.mission-canvas"
if [ -d "$INSTALL_DIR/.git" ]; then
  echo "  → Updating existing install..."
  (cd "$INSTALL_DIR" && git pull --quiet 2>/dev/null) || true
else
  echo "  ✗ Binary download failed. Please download manually from https://missioncanvas.ai"
  exit 1
fi
echo "  ✓ Source ready"

# Install Python deps (with PEP 668 break packages)
echo "  → Installing dependencies..."
cd "$INSTALL_DIR"
if pip3 install --quiet --break-system-packages pyyaml redis fastapi uvicorn websockets pytest httpx 2>/dev/null || \
   pip3 install --quiet pyyaml redis fastapi uvicorn websockets pytest httpx 2>/dev/null || \
   python3 -m pip install --quiet --break-system-packages pyyaml redis fastapi uvicorn websockets pytest httpx 2>/dev/null; then
  echo "  ✓ Dependencies"
else
  echo "  ✗ Dependency install failed"
  exit 1
fi

# Install Node.js deps if node is installed
if command -v node >/dev/null 2>&1 && [ -d "runtime" ]; then
  echo "  → Installing Node.js dependencies..."
  (cd runtime && npm install --silent 2>/dev/null) || true
fi

# Make mc command available
if [ -f "$INSTALL_DIR/mc" ]; then
  chmod +x "$INSTALL_DIR/mc"
  mkdir -p "${HOME}/.local/bin"
  ln -sf "$INSTALL_DIR/mc" "${HOME}/.local/bin/mc" 2>/dev/null || true
fi

pull_ollama

# Verify
echo ""
python3 "$INSTALL_DIR/src/mc_cli.py" health 2>/dev/null || echo "  (Run 'mc health' to verify)"

# Auto-start API server (source mode — api_server.py is on disk)
echo "  → Starting web server on http://localhost:7891 ..."
python3 src/api_server.py >/dev/null 2>&1 &

# Poll until the server binds, then open the UI
i=0
while [ "$i" -lt 30 ]; do
  if curl -fsS "http://127.0.0.1:7891/" >/dev/null 2>&1; then break; fi
  i=$((i + 1)); sleep 1
done
if [ "$i" -lt 30 ]; then
  echo "  ✓ Web UI is live"
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "http://localhost:7891" >/dev/null 2>&1 &
  elif command -v open >/dev/null 2>&1; then open "http://localhost:7891" >/dev/null 2>&1 &
  fi
fi

# Native launcher — reboot never requires a terminal after this
install_native_launcher

# Install log summary — same rationale as binary path: Ollama/Model
# are not logged here because the wizard installs them after this exits.
INSTALL_SECS=$(( $(date +%s) - INSTALL_START ))
mkdir -p "$HOME/.mission-canvas"
{
  echo "=== Install completed (source): $(date) ==="
  echo "OS: $(uname -a)"
  echo "Duration: ${INSTALL_SECS}s"
} >> "$HOME/.mission-canvas/install.log"

echo ""
echo "  ✓ Ready in ${INSTALL_SECS} seconds"
echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   Installation complete!                 ║"
echo "  ╠══════════════════════════════════════════╣"
echo "  ║   Web UI:  http://localhost:7891          ║"
echo "  ║   CLI:     cd $INSTALL_DIR && python3 src/mc_cli.py shell"
echo "  ║   Relaunch: search \"Mission Canvas\"      ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

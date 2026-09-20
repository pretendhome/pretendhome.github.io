#!/bin/sh
# Mission Canvas CLI — Developer Install
# Usage: curl -fsSL https://missioncanvas.ai/install-cli.sh | sh
#
# This installs the MC command-line tool ONLY.
# No web server. No desktop app. No browser. Just the CLI.
#
# Requirements: Python 3.11+, curl
# Optional: Ollama (for local inference)
set -e

INSTALL_START=$(date +%s)

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   Mission Canvas CLI                     ║"
echo "  ║   Governed AI from your terminal         ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# ── Preflight ───────────────────────────────────────────────────────────────

check_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "  ✗ Required: $1 not found"
    echo "    $2"
    exit 1
  fi
}

check_command python3 "Install Python 3.11+: https://python.org"
check_command curl "Install curl: https://curl.se"

PYTHON_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
PYTHON_MAJOR=$(echo "$PYTHON_VER" | cut -d. -f1)
PYTHON_MINOR=$(echo "$PYTHON_VER" | cut -d. -f2)
if [ "$PYTHON_MAJOR" -lt 3 ] || { [ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 11 ]; }; then
  echo "  ✗ Python 3.11+ required (found $PYTHON_VER)"
  exit 1
fi
echo "  ✓ Python $PYTHON_VER"

# ── Install ─────────────────────────────────────────────────────────────────

INSTALL_DIR="${MC_INSTALL_DIR:-${HOME}/.mission-canvas/cli}"
REPO="pretendhome/missioncanvas.ai"

# Detect platform
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$OS-$ARCH" in
  linux-x86_64)   ASSET="mc-linux-x86_64" ;;
  darwin-arm64)   ASSET="mc-darwin-arm64" ;;
  darwin-x86_64)  ASSET="mc-darwin-arm64" ;;  # Rosetta fallback
  *)
    echo "  ✗ Unsupported platform: $OS-$ARCH"
    echo "    Download manually from https://missioncanvas.ai"
    exit 1 ;;
esac

mkdir -p "$INSTALL_DIR"

# Download or update the CLI binary
# Release resolution: the desktop app's releases (tags desktop-v*) live in this
# same repo, so "releases/latest" can resolve to a release that carries none of
# the mc-* binaries. On 2026-09-20 it resolved to a Tropical IT release and all
# three of these downloads 404'd, which broke the install command printed on
# missioncanvas.ai. install.sh already resolves the CLI train explicitly; this
# script was missed. Resolve the newest CLI release (tag v*), and fall back to
# "latest" only when the release list itself cannot be reached.
RELEASES_API="https://api.github.com/repos/${REPO}/releases?per_page=20"
CLI_TAG=$(curl -fsSL "$RELEASES_API" 2>/dev/null \
  | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"v[0-9][^"]*"' \
  | head -1 \
  | sed 's/.*"\(v[0-9][^"]*\)"/\1/')
if [ -n "$CLI_TAG" ]; then
  DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${CLI_TAG}/${ASSET}"
else
  DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"
fi
echo "  → Downloading mc for $OS/$ARCH..."
if curl -fsSL -o "$INSTALL_DIR/mc" "$DOWNLOAD_URL"; then
  chmod +x "$INSTALL_DIR/mc"
  echo "  ✓ CLI binary ready"
else
  # Fallback: try git clone for developer install
  if [ -d "$INSTALL_DIR/.git" ]; then
    echo "  → Updating existing git install..."
    (cd "$INSTALL_DIR" && git pull --quiet 2>/dev/null) || true
    echo "  ✓ Source ready (git)"
  elif command -v git >/dev/null 2>&1; then
    echo "  → Binary download failed. Trying git clone..."
    git clone --quiet --depth 1 https://github.com/pretendhome/mission-canvas.git "$INSTALL_DIR" 2>/dev/null
    if [ $? -eq 0 ]; then
      echo "  ✓ Source ready (git clone)"
    else
      echo "  ✗ Installation failed. Please download manually from https://missioncanvas.ai"
      exit 1
    fi
  else
    echo "  ✗ Installation failed. Please download manually from https://missioncanvas.ai"
    exit 1
  fi

  # Git-based install needs Python dependencies
  echo "  → Installing dependencies..."
  cd "$INSTALL_DIR"
  CLI_DEPS="pyyaml httpx cryptography"
  if pip3 install --quiet --break-system-packages $CLI_DEPS 2>/dev/null || \
     pip3 install --quiet $CLI_DEPS 2>/dev/null || \
     python3 -m pip install --quiet --break-system-packages $CLI_DEPS 2>/dev/null; then
    echo "  ✓ Dependencies"
  else
    echo "  ✗ Dependency install failed"
    echo "    Try: pip3 install pyyaml httpx cryptography"
    exit 1
  fi
fi

# ── mc on PATH ──────────────────────────────────────────────────────────────

chmod +x "$INSTALL_DIR/mc"
mkdir -p "${HOME}/.local/bin"
ln -sf "$INSTALL_DIR/mc" "${HOME}/.local/bin/mc" 2>/dev/null || true

# Check if ~/.local/bin is on PATH
case ":$PATH:" in
  *":${HOME}/.local/bin:"*) ;;
  *)
    echo ""
    echo "  ⚠ Add ~/.local/bin to your PATH:"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo "    (add to ~/.bashrc or ~/.zshrc)"
    echo ""
    ;;
esac

# ── Ollama (optional) ──────────────────────────────────────────────────────

if command -v ollama >/dev/null 2>&1; then
  if curl -s http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    # Check if a usable model is installed
    HAS_MODEL=$(curl -s http://127.0.0.1:11434/api/tags 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print('yes' if d.get('models') else 'no')
except: print('no')
" 2>/dev/null)
    if [ "$HAS_MODEL" = "yes" ]; then
      echo "  ✓ Ollama ready (local inference available)"
    else
      echo "  → Pulling local model (qwen2.5:3b — ~2GB, one-time download)..."
      ollama pull qwen2.5:3b 2>/dev/null || true
      echo "  ✓ Local model ready"
    fi
  else
    echo "  ⚠ Ollama installed but not running. Start with: ollama serve"
  fi
else
  echo "  ℹ Ollama not installed — mc will work but without local inference"
  echo "    Install: https://ollama.com/download"
  echo "    Then: ollama pull qwen2.5:3b"
fi

# ── Verify ──────────────────────────────────────────────────────────────────

echo ""
if "$INSTALL_DIR/mc" ignition 2>/dev/null | grep -q "The car will go"; then
  echo "  ✓ mc ignition passed"
else
  echo "  ⚠ mc ignition had warnings (run 'mc ignition' for details)"
fi

# ── Done ────────────────────────────────────────────────────────────────────

INSTALL_SECS=$(( $(date +%s) - INSTALL_START ))

mkdir -p "$HOME/.mission-canvas"
{
  echo "=== CLI Install completed: $(date) ==="
  echo "OS: $(uname -a)"
  echo "Duration: ${INSTALL_SECS}s"
  echo "Dir: $INSTALL_DIR"
} >> "$HOME/.mission-canvas/install.log"

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   CLI installed in ${INSTALL_SECS}s                    ║"
echo "  ╠══════════════════════════════════════════╣"
echo "  ║                                          ║"
echo "  ║   Get started:                           ║"
echo "  ║     mc setup          # configure LLMs   ║"
echo "  ║     mc run \"query\"    # ask anything     ║"
echo "  ║     mc health         # system status    ║"
echo "  ║                                          ║"
echo "  ║   Docs: https://missioncanvas.ai/docs    ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

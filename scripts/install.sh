#!/bin/sh
# PlayPanda installer
# Usage: curl -fsSL https://raw.githubusercontent.com/ancs21/playpanda/main/scripts/install.sh | sh
set -e

REPO="ancs21/playpanda"
BIN_DIR="${PLAYPANDA_BIN_DIR:-$HOME/.local/bin}"
SCRIPTS_DIR="$HOME/.playpanda/scripts"
BASE_URL="https://raw.githubusercontent.com/$REPO/main"

echo "playpanda installer"
echo ""

# Detect platform
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$ARCH" in
  arm64|aarch64) ARCH="aarch64" ;;
  x86_64|amd64)  ARCH="x86_64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

case "$OS" in
  darwin) PLATFORM="${ARCH}-macos" ;;
  linux)  PLATFORM="${ARCH}-linux" ;;
  *) echo "Unsupported OS: $OS"; exit 1 ;;
esac

echo "  Platform: $PLATFORM"
echo "  Bin dir:  $BIN_DIR"
echo ""

# Pick downloader
if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL "$1"; }
  download() { curl -fsSL -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -qO- "$1"; }
  download() { wget -qO "$2" "$1"; }
else
  echo "Error: curl or wget required"; exit 1
fi

# --- 1. Install playpanda binary ---
echo "[1/4] Installing playpanda..."
mkdir -p "$BIN_DIR"

# Try prebuilt binary from GitHub Releases
RELEASE_URL=$(fetch "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
  | grep "browser_download_url.*$PLATFORM" | head -1 | cut -d'"' -f4) || true

if [ -n "$RELEASE_URL" ]; then
  download "$RELEASE_URL" "$BIN_DIR/playpanda"
  chmod +x "$BIN_DIR/playpanda"
  echo "  Downloaded prebuilt binary"
elif command -v zig >/dev/null 2>&1; then
  echo "  No prebuilt binary found. Building from source..."
  TMPDIR=$(mktemp -d)
  git clone --depth 1 "https://github.com/$REPO.git" "$TMPDIR/playpanda" 2>/dev/null
  cd "$TMPDIR/playpanda"
  zig build -Doptimize=ReleaseFast
  cp zig-out/bin/playpanda "$BIN_DIR/playpanda"
  rm -rf "$TMPDIR"
  echo "  Built from source"
else
  echo "  Error: No prebuilt binary and Zig not found."
  echo "  Install Zig 0.15+: https://ziglang.org/download/"
  exit 1
fi
echo "  -> $BIN_DIR/playpanda"
echo ""

# --- 2. Download helper scripts ---
echo "[2/4] Installing scripts..."
mkdir -p "$SCRIPTS_DIR"
for script in fetch_page.py harvest_cookies.py; do
  download "$BASE_URL/scripts/$script" "$SCRIPTS_DIR/$script" 2>/dev/null && \
    echo "  $script" || echo "  $script (skipped)"
done
echo ""

# --- 3. Install Lightpanda ---
echo "[3/4] Installing Lightpanda..."
LP_PATH="$BIN_DIR/lightpanda"
if [ -f "$LP_PATH" ]; then
  echo "  Already installed"
else
  download "https://github.com/lightpanda-io/browser/releases/download/nightly/lightpanda-${PLATFORM}" "$LP_PATH" 2>/dev/null && {
    chmod +x "$LP_PATH"
    echo "  -> $LP_PATH"
  } || echo "  Skipped (install manually: https://lightpanda.io/)"
fi
echo ""

# --- 4. Setup CloakBrowser wrapper + Python deps ---
echo "[4/4] Setting up dependencies..."

# CloakBrowser wrapper
CLOAK_DIR="$HOME/.cloakbrowser"
CLOAK_BIN="$CLOAK_DIR/chrome"
if [ -f "$CLOAK_BIN" ]; then
  echo "  CloakBrowser: already installed"
else
  CHROME_BIN=""
  if [ "$OS" = "darwin" ]; then
    for c in \
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
      "/Applications/Chromium.app/Contents/MacOS/Chromium" \
      "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"; do
      [ -f "$c" ] && CHROME_BIN="$c" && break
    done
  else
    for c in google-chrome chromium chromium-browser brave-browser; do
      command -v "$c" >/dev/null 2>&1 && CHROME_BIN=$(command -v "$c") && break
    done
  fi

  if [ -n "$CHROME_BIN" ]; then
    mkdir -p "$CLOAK_DIR/profiles/default"
    cat > "$CLOAK_BIN" << EOF
#!/bin/sh
exec "$CHROME_BIN" --user-data-dir="\$HOME/.cloakbrowser/profiles/default" --window-size=1920,1080 "\$@"
EOF
    chmod +x "$CLOAK_BIN"
    echo "  CloakBrowser: using $CHROME_BIN"
  else
    echo "  CloakBrowser: no Chrome found (Tier 3 won't work, Tier 1+2 still fine)"
  fi
fi

# Python websockets
if python3 -c "import websockets" 2>/dev/null; then
  echo "  websockets: already installed"
else
  pip3 install --break-system-packages websockets 2>/dev/null \
    || pip3 install websockets 2>/dev/null \
    || echo "  websockets: install manually -> pip3 install websockets"
fi
echo ""

# --- Check PATH ---
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo "Add to PATH:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
    echo ""
    SHELL_NAME=$(basename "$SHELL" 2>/dev/null || echo "sh")
    case "$SHELL_NAME" in
      zsh)  echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" ;;
      bash) echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc" ;;
    esac
    echo ""
    ;;
esac

echo "Done! Get started:"
echo "  playpanda https://example.com"
echo "  playpanda profile"
echo "  playpanda --help"

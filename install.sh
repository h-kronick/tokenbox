#!/bin/bash
# TokenBox — One-command installer
# Usage: curl -fsSL https://tokenbox.club/install | bash
set -euo pipefail

AMBER='\033[38;2;212;168;67m'
DIM='\033[2m'
BOLD='\033[1m'
GREEN='\033[32m'
RED='\033[31m'
RESET='\033[0m'

step() { echo -e "\n${AMBER}▸${RESET} ${BOLD}$1${RESET}"; }
ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
warn() { echo -e "  ${DIM}⚠ $1${RESET}"; }
fail() { echo -e "  ${RED}✗ $1${RESET}"; exit 1; }

# ── Platform detection ─────────────────────────────────────────
OS="$(uname -s)"
MACOS_NATIVE=false
if [ "$OS" = "Darwin" ]; then
  MAC_VER=$(sw_vers -productVersion 2>/dev/null || echo "0")
  MAJOR=$(echo "$MAC_VER" | cut -d. -f1)
  if [ "$MAJOR" -ge 14 ] 2>/dev/null; then
    MACOS_NATIVE=true
  fi
fi

echo -e "${AMBER}"
cat << 'BANNER'
  ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐
  │ T │ │ O │ │ K │ │ E │ │ N │ │ B │ │ O │ │ X │
  ├───┤ ├───┤ ├───┤ ├───┤ ├───┤ ├───┤ ├───┤ ├───┤
  └───┘ └───┘ └───┘ └───┘ └───┘ └───┘ └───┘ └───┘
                TokenBox Installer
BANNER
echo -e "${RESET}"

INSTALL_DIR="$HOME/.tokenbox"
REPO_DIR="$INSTALL_DIR/repo"
HOOK_DIR="$INSTALL_DIR/hooks"
SKILL_DIR="$HOME/.claude/skills/tokenbox"
SETTINGS="$HOME/.claude/settings.json"
BIN_DIR="$HOME/.local/bin"

# Platform-aware data directory
case "$OS" in
  Darwin) DATA_DIR="$HOME/Library/Application Support/TokenBox" ;;
  Linux)  DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/tokenbox" ;;
  *)      DATA_DIR="$HOME/.tokenbox/data" ;;
esac

# ── 1. Prerequisites ────────────────────────────────────────────
step "Checking prerequisites"

if ! command -v git &>/dev/null; then fail "git not found — install git first"; fi
ok "git"

if ! command -v node &>/dev/null; then
  fail "Node.js not found — install Node.js 18+ (required for TUI and skill)"
else
  NODE_VER=$(node -v | grep -oE '[0-9]+' | head -1)
  if [ "$NODE_VER" -lt 18 ] 2>/dev/null; then
    fail "Node.js 18+ required (found $(node -v))"
  fi
  ok "node $(node -v)"
fi

if [ "$MACOS_NATIVE" = "true" ]; then
  if ! command -v swift &>/dev/null; then fail "swift not found — install Xcode or Xcode CLI tools"; fi
  ok "swift $(swift --version 2>&1 | grep -oE 'Swift version [0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' | head -1)"

  if ! command -v jq &>/dev/null; then
    warn "jq not found — installing via brew"
    if command -v brew &>/dev/null; then
      brew install jq --quiet
      ok "jq installed"
    else
      warn "jq not found and no brew — status hook needs jq. Install: brew install jq"
    fi
  else
    ok "jq"
  fi
fi

# ── 2. Clone / Update Repo ──────────────────────────────────────
step "Getting TokenBox"

mkdir -p "$INSTALL_DIR"

if [ -d "$REPO_DIR/.git" ]; then
  echo "  Updating existing install..."
  (cd "$REPO_DIR" && git pull --quiet origin main 2>/dev/null) || true
  ok "Updated"
else
  echo "  Cloning from GitHub..."
  git clone --quiet https://github.com/h-kronick/tokenbox.git "$REPO_DIR"
  ok "Cloned to $REPO_DIR"
fi

# ── 3. Build ─────────────────────────────────────────────────────
if [ "$MACOS_NATIVE" = "true" ]; then
  step "Building TokenBox (native app)"
  echo "  This may take a minute on first build..."

  (cd "$REPO_DIR" && swift build 2>&1 | grep -E "Build complete|error:" | tail -3)

  BIN="$REPO_DIR/.build/arm64-apple-macosx/debug/TokenBox"
  if [ ! -f "$BIN" ]; then
    # Try x86 path
    BIN="$REPO_DIR/.build/x86_64-apple-macosx/debug/TokenBox"
  fi
  if [ ! -f "$BIN" ]; then
    BIN="$(cd "$REPO_DIR" && swift build --show-bin-path)/TokenBox"
  fi

  if [ -f "$BIN" ]; then
    ok "Built successfully"
  else
    fail "Build failed — check swift build output"
  fi
fi

step "Installing terminal UI"
(cd "$REPO_DIR/tui" && npm ci --production 2>&1 | tail -1)
ok "Terminal UI ready"

# ── 4. Install Hook ──────────────────────────────────────────────
step "Installing status relay hook"

mkdir -p "$HOOK_DIR"
if [ "$MACOS_NATIVE" = "true" ]; then
  cp "$REPO_DIR/hooks/status-relay.sh" "$HOOK_DIR/status-relay.sh"
  chmod +x "$HOOK_DIR/status-relay.sh"
  HOOK_CMD="$HOOK_DIR/status-relay.sh"
else
  cp "$REPO_DIR/hooks/status-relay.mjs" "$HOOK_DIR/status-relay.mjs"
  chmod +x "$HOOK_DIR/status-relay.mjs"
  HOOK_CMD="node $HOOK_DIR/status-relay.mjs"
fi
ok "Hook installed to $HOOK_DIR/"

# ── 5. Configure Claude Code Hook ───────────────────────────────
step "Configuring Claude Code"

mkdir -p "$HOME/.claude"

if [ -f "$SETTINGS" ]; then
  # Check if statusLine is already configured
  if grep -q "status-relay" "$SETTINGS" 2>/dev/null; then
    # Migrate old "hooks.Status" config to "statusLine" if needed
    if grep -q '"Status"' "$SETTINGS" 2>/dev/null; then
      cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
      node -e "
const fs = require('fs');
const path = process.argv[1];
const cmd = process.argv[2];
try {
  const settings = JSON.parse(fs.readFileSync(path, 'utf8'));
  if (settings.hooks && settings.hooks.Status) {
    delete settings.hooks.Status;
    if (Object.keys(settings.hooks).length === 0) delete settings.hooks;
  }
  settings.statusLine = { type: 'command', command: cmd };
  fs.writeFileSync(path, JSON.stringify(settings, null, 2) + '\n');
} catch(e) { process.exit(1); }
" "$SETTINGS" "$HOOK_CMD" 2>/dev/null && ok "Migrated Status hook to statusLine" || ok "Status relay already configured"
    else
      ok "Status relay already configured"
    fi
  else
    # Back up settings before modifying
    cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"

    # Add statusLine to existing settings (node available on all platforms)
    node -e "
const fs = require('fs');
const path = process.argv[1];
const cmd = process.argv[2];
try {
  const settings = JSON.parse(fs.readFileSync(path, 'utf8'));
  if (settings.hooks && settings.hooks.Status) {
    delete settings.hooks.Status;
    if (Object.keys(settings.hooks).length === 0) delete settings.hooks;
  }
  settings.statusLine = { type: 'command', command: cmd };
  fs.writeFileSync(path, JSON.stringify(settings, null, 2) + '\n');
} catch(e) { process.exit(1); }
" "$SETTINGS" "$HOOK_CMD" 2>/dev/null && ok "Status relay added to settings.json" || warn "Could not auto-configure — add statusLine manually (see README)"
  fi
else
  # Create new settings.json
  cat > "$SETTINGS" << SETTINGSJSON
{
  "statusLine": {
    "type": "command",
    "command": "$HOOK_CMD"
  }
}
SETTINGSJSON
  ok "Created settings.json with status relay"
fi

# ── 6. Install Skill ─────────────────────────────────────────────
step "Installing Claude Code skill"

mkdir -p "$(dirname "$SKILL_DIR")"
ln -sf "$REPO_DIR/skill" "$SKILL_DIR"

(cd "$REPO_DIR/skill" && npm install --omit=dev --silent 2>&1 | tail -1)
ok "Skill installed with dependencies"

# ── 7. Create CLI Command ────────────────────────────────────────
step "Creating 'tokenbox' command"

mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/tokenbox" << 'LAUNCHER'
#!/bin/bash
set -euo pipefail

INSTALL_DIR="$HOME/.tokenbox"
REPO_DIR="$INSTALL_DIR/repo"

# Detect platform
_OS="$(uname -s)"
_MACOS_NATIVE=false
if [ "$_OS" = "Darwin" ]; then
  _MAJOR=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)
  if [ "$_MAJOR" -ge 14 ] 2>/dev/null; then
    _MACOS_NATIVE=true
  fi
fi

launch_tui() {
  exec node "$REPO_DIR/tui/index.mjs" "$@"
}

launch_native() {
  BIN="$(cd "$REPO_DIR" && swift build --show-bin-path 2>/dev/null)/TokenBox"
  if [ ! -f "$BIN" ]; then
    echo "Rebuilding TokenBox..."
    (cd "$REPO_DIR" && swift build) || exit 1
    BIN="$(cd "$REPO_DIR" && swift build --show-bin-path)/TokenBox"
  fi
  if pgrep -x "TokenBox" > /dev/null 2>&1; then
    osascript -e 'tell application "System Events" to set frontmost of (first process whose name is "TokenBox") to true' 2>/dev/null
    echo "TokenBox brought to front."
  else
    LOG_FILE="$(mktemp -t tokenbox.XXXXXX.log)"
    "$BIN" >"$LOG_FILE" 2>&1 &
    disown
    echo "TokenBox launched."
    (while kill -0 $! 2>/dev/null; do sleep 5; done; rm -f "$LOG_FILE") &
    disown
  fi
}

case "${1:-}" in
  uninstall)
    shift
    if [ -f "$REPO_DIR/uninstall.sh" ]; then
      exec "$REPO_DIR/uninstall.sh" "$@"
    else
      echo "Uninstall script not found. Run manually:"
      echo "  curl -fsSL https://tokenbox.club/install | bash"
      exit 1
    fi
    ;;
  update)
    echo "Updating TokenBox..."
    (cd "$REPO_DIR" && git pull --quiet origin main 2>/dev/null) || true
    if [ "$_MACOS_NATIVE" = "true" ]; then
      (cd "$REPO_DIR" && swift build 2>&1 | grep -E "Build complete|error:" | tail -3)
    fi
    (cd "$REPO_DIR/tui" && npm ci --production 2>&1 | tail -1)
    echo "Updated. Restart TokenBox to apply changes."
    ;;
  tui)
    shift
    launch_tui "$@"
    ;;
  help|--help|-h)
    echo "Usage: tokenbox [command]"
    echo ""
    echo "Commands:"
    echo "  (none)          Launch TokenBox (native app on macOS, TUI elsewhere)"
    echo "  tui             Launch terminal UI (any platform)"
    echo "  uninstall       Remove TokenBox completely"
    echo "  uninstall --keep-data  Remove but keep token history"
    echo "  update          Pull latest and rebuild"
    echo "  help            Show this help"
    ;;
  "")
    if [ "$_MACOS_NATIVE" = "true" ]; then
      launch_native
    else
      launch_tui
    fi
    ;;
  *)
    echo "Unknown command: $1"
    echo "Run 'tokenbox help' for usage."
    exit 1
    ;;
esac
LAUNCHER
chmod +x "$BIN_DIR/tokenbox"
ok "Run 'tokenbox' from any terminal"

# Check PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  warn "$BIN_DIR is not in your PATH. Add to your shell profile:"
  echo -e "    ${DIM}export PATH=\"\$HOME/.local/bin:\$PATH\"${RESET}"
fi

# ── 8. Create Data Directory ─────────────────────────────────────
mkdir -p "$DATA_DIR"

# ── Done ──────────────────────────────────────────────────────────
echo ""
echo -e "${AMBER}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}  TokenBox installed successfully!${RESET}"
echo -e "${AMBER}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  ${BOLD}Launch:${RESET}  Type ${AMBER}tokenbox${RESET} anywhere in your terminal"
echo -e "  ${BOLD}Usage:${RESET}   Token tracking starts automatically"
echo -e "           as you use Claude Code."
echo -e "  ${BOLD}Update:${RESET} tokenbox update"
echo -e "  ${BOLD}Remove:${RESET} tokenbox uninstall"
echo ""

# Launch
if [ "$MACOS_NATIVE" = "true" ]; then
  # macOS: auto-launch when piped from curl (no tty), prompt when run interactively
  if [ -t 0 ]; then
    read -p "  Launch TokenBox now? [Y/n] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
      exit 0
    fi
  fi

  echo -e "  ${DIM}Launching...${RESET}"
  "$BIN" >/dev/null 2>&1 &
  disown
  echo -e "  ${GREEN}✓${RESET} TokenBox is running in your menu bar"
else
  # Other platforms: launch TUI
  if [ -t 0 ]; then
    read -p "  Launch TokenBox TUI now? [Y/n] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
      exit 0
    fi
  fi

  echo -e "  ${DIM}Launching TUI...${RESET}"
  echo -e "  ${GREEN}✓${RESET} TokenBox TUI is running in your terminal"
  exec node "$REPO_DIR/tui/index.mjs"
fi

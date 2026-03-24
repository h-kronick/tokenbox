#!/bin/bash
# TokenBox — Uninstaller
# Removes all TokenBox artifacts: hook, skill, CLI, app data, settings entries
set -euo pipefail

AMBER='\033[38;2;212;168;67m'
DIM='\033[2m'
BOLD='\033[1m'
GREEN='\033[32m'
RED='\033[31m'
RESET='\033[0m'

step() { echo -e "\n${AMBER}▸${RESET} ${BOLD}$1${RESET}"; }
ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
skip() { echo -e "  ${DIM}— $1${RESET}"; }
warn() { echo -e "  ${RED}!${RESET} $1"; }

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
               TokenBox Uninstall
BANNER
echo -e "${RESET}"

INSTALL_DIR="$HOME/.tokenbox"
SKILL_DIR="$HOME/.claude/skills/tokenbox"
SETTINGS="$HOME/.claude/settings.json"
BIN_CMD="$HOME/.local/bin/tokenbox"

# Platform-aware data directory
case "$OS" in
  Darwin) DATA_DIR="$HOME/Library/Application Support/TokenBox" ;;
  Linux)  DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/tokenbox" ;;
  *)      DATA_DIR="$HOME/.tokenbox/data" ;;
esac

KEEP_DATA=false
SKIP_CONFIRM=false
for arg in "$@"; do
  case "$arg" in
    --keep-data) KEEP_DATA=true ;;
    --yes|-y) SKIP_CONFIRM=true ;;
    --help|-h)
      echo "Usage: ./uninstall.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --keep-data   Keep token history, sharing credentials, and preferences"
      echo "  --yes, -y     Skip confirmation prompt"
      echo "  --help        Show this help"
      exit 0
      ;;
  esac
done

# ── Confirmation ──────────────────────────────────────────────────
if [ "$SKIP_CONFIRM" = false ] && [ -t 0 ]; then
  echo -e "  This will remove TokenBox from your system."
  echo ""
  echo -e "  ${BOLD}[Enter]${RESET}  Uninstall and ${RED}delete all data${RESET} (token history, sharing, preferences)"
  echo -e "  ${BOLD}[k]${RESET}      Uninstall but ${GREEN}keep your data${RESET} (reinstall later without losing anything)"
  echo -e "  ${BOLD}[c]${RESET}      Cancel"
  echo ""
  read -p "  Your choice: " -n 1 -r
  echo
  case "$REPLY" in
    k|K) KEEP_DATA=true ;;
    c|C|n|N) echo -e "  ${DIM}Cancelled.${RESET}"; exit 0 ;;
    "") ;; # Enter = proceed with full uninstall
    *) echo -e "  ${DIM}Cancelled.${RESET}"; exit 0 ;;
  esac
fi

# ── 1. Kill running processes ────────────────────────────────────
step "Stopping TokenBox"

STOPPED=false

if [ "$OS" = "Darwin" ]; then
  if pgrep -x "TokenBox" > /dev/null 2>&1; then
    killall TokenBox 2>/dev/null || true
    sleep 1
    if pgrep -x "TokenBox" > /dev/null 2>&1; then
      killall -9 TokenBox 2>/dev/null || true
    fi
    ok "Native app stopped"
    STOPPED=true
  fi
fi

# Kill TUI process
if pkill -f "node.*tui/index.mjs" 2>/dev/null; then
  ok "TUI stopped"
  STOPPED=true
fi

if [ "$STOPPED" = false ]; then
  skip "Not running"
fi

# ── 2. Remove hook from Claude Code settings ─────────────────────
step "Removing Claude Code hook"

if [ -f "$SETTINGS" ]; then
  if grep -q "status-relay" "$SETTINGS" 2>/dev/null; then
    cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
    node -e "
const fs = require('fs');
const path = process.argv[1];
try {
  const settings = JSON.parse(fs.readFileSync(path, 'utf8'));
  if (settings.statusLine && (settings.statusLine.command || '').includes('status-relay')) {
    delete settings.statusLine;
  }
  if (settings.hooks && settings.hooks.Status) {
    delete settings.hooks.Status;
    if (Object.keys(settings.hooks).length === 0) delete settings.hooks;
  }
  fs.writeFileSync(path, JSON.stringify(settings, null, 2) + '\n');
} catch(e) { process.exit(1); }
" "$SETTINGS" 2>/dev/null && ok "Status relay removed from settings.json" || warn "Could not auto-remove — edit $SETTINGS manually"
  else
    skip "Hook not in settings.json"
  fi
else
  skip "No settings.json found"
fi

# ── 3. Remove skill symlink ──────────────────────────────────────
step "Removing Claude Code skill"

if [ -L "$SKILL_DIR" ] || [ -d "$SKILL_DIR" ]; then
  rm -rf "$SKILL_DIR"
  ok "Removed $SKILL_DIR"
else
  skip "Skill not installed"
fi

# ── 4. Remove CLI command ─────────────────────────────────────────
step "Removing 'tokenbox' command"

if [ -f "$BIN_CMD" ]; then
  rm -f "$BIN_CMD"
  ok "Removed $BIN_CMD"
else
  skip "CLI not installed"
fi

# ── 5. Remove install directory (repo + hooks) ───────────────────
step "Removing installation directory"

if [ -d "$INSTALL_DIR" ]; then
  rm -rf "$INSTALL_DIR"
  ok "Removed $INSTALL_DIR"
else
  skip "Not found"
fi

# ── 6. Remove app data ───────────────────────────────────────────
step "Removing app data"

if [ "$KEEP_DATA" = true ]; then
  skip "Kept (--keep-data flag)"
elif [ -d "$DATA_DIR" ]; then
  rm -rf "$DATA_DIR"
  ok "Removed $DATA_DIR"
else
  skip "No app data found"
fi

# ── 7. Remove preferences (macOS only) ───────────────────────────
if [ "$OS" = "Darwin" ]; then
  step "Removing preferences"

  if [ "$KEEP_DATA" = true ]; then
    skip "Kept (--keep-data flag)"
  elif defaults read TokenBox &>/dev/null 2>&1; then
    defaults delete TokenBox
    ok "Removed TokenBox defaults"
  else
    skip "No preferences found"
  fi
fi

# ── Done ──────────────────────────────────────────────────────────
echo ""
echo -e "${AMBER}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}  TokenBox uninstalled.${RESET}"
echo -e "${AMBER}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
if [ "$KEEP_DATA" = true ]; then
  echo -e "  ${DIM}App data preserved at: $DATA_DIR${RESET}"
  echo -e "  ${DIM}Reinstall with: curl -fsSL https://tokenbox.club/install | bash${RESET}"
else
  echo -e "  ${DIM}All TokenBox files removed. Reinstall anytime:${RESET}"
  echo -e "  ${DIM}curl -fsSL https://tokenbox.club/install | bash${RESET}"
fi
echo ""

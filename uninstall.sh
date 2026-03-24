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

echo -e "${AMBER}"
cat << 'BANNER'
  ╔═══════════════════════════╗
  ║     TokenBox Uninstall     ║
  ╚═══════════════════════════╝
BANNER
echo -e "${RESET}"

INSTALL_DIR="$HOME/.tokenbox"
DATA_DIR="$HOME/Library/Application Support/TokenBox"
SKILL_DIR="$HOME/.claude/skills/tokenbox"
SETTINGS="$HOME/.claude/settings.json"
BIN_CMD="$HOME/.local/bin/tokenbox"

KEEP_DATA=false
for arg in "$@"; do
  case "$arg" in
    --keep-data) KEEP_DATA=true ;;
    --help|-h)
      echo "Usage: ./uninstall.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --keep-data   Keep SQLite database and app data (only remove hooks/skill/CLI)"
      echo "  --help        Show this help"
      exit 0
      ;;
  esac
done

# ── 1. Kill running app ──────────────────────────────────────────
step "Stopping TokenBox"

if pgrep -x "TokenBox" > /dev/null 2>&1; then
  killall TokenBox 2>/dev/null || true
  # Wait briefly for clean shutdown
  sleep 1
  # Force kill if still running
  if pgrep -x "TokenBox" > /dev/null 2>&1; then
    killall -9 TokenBox 2>/dev/null || true
  fi
  ok "App stopped"
else
  skip "Not running"
fi

# ── 2. Remove hook from Claude Code settings ─────────────────────
step "Removing Claude Code hook"

if [ -f "$SETTINGS" ]; then
  if grep -q "status-relay" "$SETTINGS" 2>/dev/null; then
    cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
    python3 - "$SETTINGS" << 'PYREMOVE' 2>/dev/null && ok "Status relay removed from settings.json" || warn "Could not auto-remove — edit $SETTINGS manually"
import json, sys

settings_path = sys.argv[1]

with open(settings_path, 'r') as f:
    settings = json.load(f)

# Remove statusLine if it points to status-relay
if 'statusLine' in settings:
    cmd = settings['statusLine'].get('command', '')
    if 'status-relay' in cmd:
        del settings['statusLine']

# Also clean up old invalid hooks.Status key if present
if 'hooks' in settings and 'Status' in settings['hooks']:
    del settings['hooks']['Status']
    if not settings['hooks']:
        del settings['hooks']

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
PYREMOVE
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

# ── 7. Remove UserDefaults ────────────────────────────────────────
step "Removing preferences"

if [ "$KEEP_DATA" = true ]; then
  skip "Kept (--keep-data flag)"
elif defaults read com.tokenbox.app &>/dev/null 2>&1; then
  defaults delete com.tokenbox.app
  ok "Removed com.tokenbox.app defaults"
else
  skip "No preferences found"
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

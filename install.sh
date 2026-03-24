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

echo -e "${AMBER}"
cat << 'BANNER'
  ╔═══════════════════════════╗
  ║  ▄▄▄▄▄ ▄▄▄▄▄ ▄▄▄▄▄ ▄▄▄  ║
  ║  █ T █ █ O █ █ K █ █ N █  ║
  ║  ▀▀▀▀▀ ▀▀▀▀▀ ▀▀▀▀▀ ▀▀▀  ║
  ║     TokenBox Installer     ║
  ╚═══════════════════════════╝
BANNER
echo -e "${RESET}"

INSTALL_DIR="$HOME/.tokenbox"
REPO_DIR="$INSTALL_DIR/repo"
HOOK_DIR="$INSTALL_DIR/hooks"
DATA_DIR="$HOME/Library/Application Support/TokenBox"
SKILL_DIR="$HOME/.claude/skills/tokenbox"
SETTINGS="$HOME/.claude/settings.json"
BIN_DIR="$HOME/.local/bin"

# ── 1. Prerequisites ────────────────────────────────────────────
step "Checking prerequisites"

if ! command -v git &>/dev/null; then fail "git not found — install Xcode CLI tools: xcode-select --install"; fi
ok "git"

if ! command -v swift &>/dev/null; then fail "swift not found — install Xcode or Xcode CLI tools"; fi
ok "swift $(swift --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)"

if ! command -v node &>/dev/null; then
  warn "Node.js not found — skill features will be limited (app still works)"
  HAS_NODE=false
else
  ok "node $(node -v)"
  HAS_NODE=true
fi

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
step "Building TokenBox"
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

# ── 4. Install Hook ──────────────────────────────────────────────
step "Installing status relay hook"

mkdir -p "$HOOK_DIR"
cp "$REPO_DIR/hooks/status-relay.sh" "$HOOK_DIR/status-relay.sh"
chmod +x "$HOOK_DIR/status-relay.sh"
ok "Hook installed to $HOOK_DIR/"

# ── 5. Configure Claude Code Hook ───────────────────────────────
step "Configuring Claude Code"

mkdir -p "$HOME/.claude"

HOOK_CMD="$HOOK_DIR/status-relay.sh"

if [ -f "$SETTINGS" ]; then
  # Check if hook is already configured
  if grep -q "status-relay" "$SETTINGS" 2>/dev/null; then
    ok "Status hook already configured"
  else
    # Back up settings before modifying
    cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"

    # Merge hook into existing settings using python (available on macOS)
    python3 - "$SETTINGS" "$HOOK_CMD" << 'PYMERGE' 2>/dev/null && ok "Status hook added to settings.json" || warn "Could not auto-configure — add hook manually (see README)"
import json, sys

settings_path = sys.argv[1]
hook_cmd = sys.argv[2]

with open(settings_path, 'r') as f:
    content = f.read().strip()
    try:
        settings = json.loads(content)
    except json.JSONDecodeError:
        print("WARNING: settings.json contains malformed JSON — skipping auto-configure.", file=sys.stderr)
        sys.exit(1)

hook_entry = {
    'matcher': '',
    'hooks': [{'type': 'command', 'command': hook_cmd}]
}

if 'hooks' not in settings:
    settings['hooks'] = {}
if 'Status' not in settings['hooks']:
    settings['hooks']['Status'] = []

# Don't add duplicate
existing = [h for h in settings['hooks']['Status'] if any(hk.get('command','').endswith('status-relay.sh') for hk in h.get('hooks',[]))]
if not existing:
    settings['hooks']['Status'].append(hook_entry)

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
PYMERGE
  fi
else
  # Create new settings.json
  cat > "$SETTINGS" << SETTINGSJSON
{
  "hooks": {
    "Status": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$HOOK_CMD"
          }
        ]
      }
    ]
  }
}
SETTINGSJSON
  ok "Created settings.json with status hook"
fi

# ── 6. Install Skill ─────────────────────────────────────────────
step "Installing Claude Code skill"

mkdir -p "$(dirname "$SKILL_DIR")"
ln -sf "$REPO_DIR/skill" "$SKILL_DIR"

if [ "$HAS_NODE" = true ]; then
  (cd "$REPO_DIR/skill" && npm install --omit=dev --quiet 2>/dev/null)
  ok "Skill installed with dependencies"
else
  ok "Skill linked (install Node.js for full functionality)"
fi

# ── 7. Create CLI Command ────────────────────────────────────────
step "Creating 'tokenbox' command"

mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/tokenbox" << 'LAUNCHER'
#!/bin/bash
set -euo pipefail

INSTALL_DIR="$HOME/.tokenbox"
REPO_DIR="$INSTALL_DIR/repo"

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
    (cd "$REPO_DIR" && swift build 2>&1 | grep -E "Build complete|error:" | tail -3)
    echo "Updated. Restart TokenBox to apply changes."
    ;;
  help|--help|-h)
    echo "Usage: tokenbox [command]"
    echo ""
    echo "Commands:"
    echo "  (none)          Launch or bring TokenBox to front"
    echo "  uninstall       Remove TokenBox completely"
    echo "  uninstall --keep-data  Remove but keep token history"
    echo "  update          Pull latest and rebuild"
    echo "  help            Show this help"
    ;;
  "")
    # Find the built binary
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
echo -e "  ${BOLD}Launch:${RESET}  tokenbox"
echo -e "  ${BOLD}Usage:${RESET}   Token tracking starts automatically"
echo -e "           as you use Claude Code."
echo -e "  ${BOLD}Remove:${RESET}  tokenbox uninstall"
echo ""

# Launch it
read -p "  Launch TokenBox now? [Y/n] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
  tokenbox 2>/dev/null || "$BIN" &disown
fi

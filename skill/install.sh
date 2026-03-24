#!/bin/bash
# TokenBox Installer — sets up hook, creates directories, installs deps
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_DEST="$HOME/.tokenbox/hooks"
DATA_DIR="$HOME/Library/Application Support/TokenBox"

echo "=== TokenBox Installer ==="
echo ""

# 1. Create directories
echo "[1/4] Creating directories..."
mkdir -p "$HOOK_DEST"
mkdir -p "$DATA_DIR"
echo "  Created $HOOK_DEST"
echo "  Created $DATA_DIR"

# 2. Copy hook script
echo "[2/4] Installing status relay hook..."
HOOK_SRC="$SCRIPT_DIR/../hooks/status-relay.sh"
if [ ! -f "$HOOK_SRC" ]; then
  echo "  ERROR: Cannot find hooks/status-relay.sh relative to this script."
  echo "  Expected at: $HOOK_SRC"
  exit 1
fi
cp "$HOOK_SRC" "$HOOK_DEST/status-relay.sh"
chmod +x "$HOOK_DEST/status-relay.sh"
echo "  Installed $HOOK_DEST/status-relay.sh"

# 3. Install Node.js dependencies
echo "[3/4] Installing Node.js dependencies..."
if ! command -v node &>/dev/null; then
  echo "  WARNING: Node.js not found. Please install Node.js >= 18 and re-run."
else
  NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
  if [ "$NODE_VERSION" -lt 18 ]; then
    echo "  WARNING: Node.js >= 18 required, found v$NODE_VERSION"
  else
    echo "  Node.js $(node -v) detected"
  fi
fi

if ! command -v npm &>/dev/null; then
  echo "  WARNING: npm not found. Skipping dependency install."
else
  (cd "$SCRIPT_DIR" && npm install --omit=dev)
  echo "  Dependencies installed"
fi

# 4. Print hook configuration snippet
echo "[4/4] Hook configuration"
echo ""
echo "  Add the following to your ~/.claude/settings.json to enable real-time tracking:"
echo ""
echo '  {
    "hooks": {
      "Status": [
        {
          "matcher": "",
          "hooks": [
            {
              "type": "command",
              "command": "'"$HOOK_DEST"'/status-relay.sh"
            }
          ]
        }
      ]
    }
  }'
echo ""
echo "  NOTE: This script does NOT modify settings.json automatically."
echo "  Please add the hook configuration manually or merge it with your existing settings."
echo ""
echo "=== TokenBox installed successfully ==="
echo ""
echo "To verify the hook works, run:"
echo '  echo '"'"'{"session_id":"test","model":{"id":"claude-sonnet-4-6"},"cost":{"total_cost_usd":0},"context_window":{"current_usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}'"'"' | '"$HOOK_DEST"'/status-relay.sh'
echo '  cat "'"$DATA_DIR"'/live.json"'

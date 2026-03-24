# TokenBox Windows Port

Cross-platform split-flap display for Claude token usage, built with Tauri 2 (Rust + HTML/CSS/JS).

See [WINDOWS-PORT.md](../WINDOWS-PORT.md) for the full porting specification.

## Prerequisites

- **Rust toolchain**: Install via [rustup](https://rustup.rs/)
- **Node.js 18+**: Required for the frontend build and hook/skill scripts
- **Windows 10+** with [WebView2](https://developer.microsoft.com/en-us/microsoft-edge/webview2/) (pre-installed on Windows 11)
- macOS also supported for development (uses system WebView)

## Quick Start

```bash
# Install frontend dependencies
cd Windows
npm install

# Run in development mode (hot-reload)
npm run dev

# Build release binary
npm run build
```

The built app is output to `src-tauri/target/release/` (binary) and `src-tauri/target/release/bundle/` (installer).

## Hook Setup

TokenBox receives real-time token data from Claude Code via a status hook.

### Automatic Setup

```bash
# Cross-platform (Node.js)
node installer/install.mjs

# Windows-only (PowerShell)
powershell -ExecutionPolicy Bypass -File installer/install.ps1
```

### Manual Setup

1. Copy `hooks/status-relay.mjs` to `~/.tokenbox/hooks/`
2. Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "node ~/.tokenbox/hooks/status-relay.mjs"
  }
}
```

## Architecture

```
Windows/
  hooks/status-relay.mjs    — Claude Code hook (writes live.json + events.jsonl)
  installer/install.mjs     — Cross-platform Node.js installer
  installer/install.ps1     — Windows PowerShell installer
  src-tauri/                 — Rust backend (Tauri 2)
    build.rs                 — Tauri build script
    Cargo.toml               — Rust dependencies
    tauri.conf.json          — Tauri window/tray config
    capabilities/            — Tauri 2 permission capabilities
    src/main.rs              — Rust entry point
    icons/                   — App icons (generated placeholders)
  src/                       — Frontend (HTML/CSS/JS)
  package.json               — Node.js project config
```

### Data Flow

```
Claude Code → Status Hook → live.json (atomic write)
  → Tauri file watcher → Frontend → Split-Flap UI

Claude Code → JSONL logs → Tauri file watcher
  → JSONL parser → SQLite → Frontend
```

### Data Directories

| Platform | Path |
|----------|------|
| Windows  | `%APPDATA%\TokenBox\` |
| macOS    | `~/Library/Application Support/TokenBox/` |

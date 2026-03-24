# TokenBox

A split-flap display for your Claude token usage. Native macOS app + cross-platform terminal UI with real-time streaming updates.

```
  ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐
  │ T │ │ O │ │ K │ │ E │ │ N │ │ B │ │ O │ │ X │
  ├───┤ ├───┤ ├───┤ ├───┤ ├───┤ ├───┤ ├───┤ ├───┤
  └───┘ └───┘ └───┘ └───┘ └───┘ └───┘ └───┘ └───┘
```

## Install

One command:

```bash
curl -fsSL https://tokenbox.club/install | bash
```

This clones the repo, builds the app, installs the Claude Code hook, links the skill, and creates the `tokenbox` CLI command. Everything is local — no cloud, no accounts, no telemetry.

### Requirements (macOS)

- macOS 14+
- Xcode Command Line Tools (`xcode-select --install`)
- Node.js 18+ (required for TUI and skill)
- `jq` (for the status hook — `brew install jq`)

### Other Platforms (Linux, Windows, older macOS)

The terminal UI works anywhere with Node.js 18+:

```bash
tokenbox tui    # Launch terminal UI
```

No Swift or Xcode required — the TUI is pure Node.js with real-time split-flap animation.

## Usage

```bash
tokenbox            # Launch or bring to front (macOS native)
tokenbox tui        # Launch terminal UI (any platform)
tokenbox update     # Pull latest and rebuild
tokenbox uninstall  # Remove everything
tokenbox help       # Show all commands
```

Token tracking starts automatically as you use Claude Code. The split-flap display updates in real-time.

### What you see

- **Top row (6 modules)**: Today's token count — flips in real-time as Claude streams responses
- **Middle row**: Rotating label — WEEK, MONTH, TOTAL, or friend names
- **Bottom row (6 modules)**: Token count for the label above

### How it works

```
Claude Code → statusLine hook → live.json → File watcher → App/TUI → Split-Flap UI
Claude Code → JSONL logs      → File watcher → Parser    → SQLite  → App/TUI
```

1. A **statusLine script** captures token data from every Claude Code interaction and writes to a local `live.json` file
2. A **JSONL watcher** monitors `~/.claude/projects/` for session logs and backfills historical data
3. The app reads both sources via file watchers (FSEvents on macOS, chokidar in TUI) for sub-second latency

All data stays on your machine in a local SQLite database.

### Menu bar icon (macOS)

On macOS, a miniature split-flap icon lives in your menu bar. The amber flaps animate when tokens are actively streaming.

### Ask about usage in Claude Code

With the skill installed, ask Claude Code directly:

```
> how many tokens have I used today?
> token stats
> usage report
```

## Display Modes

### Real-time streaming (default: ON)

The top counter updates with every intermediate streaming event for maximum flip action. The physical split-flap board receives the same values and catches up at its mechanical speed.

Toggle in **Preferences > General > Real-time streaming display**.

### Color themes

| Theme | Look |
|-------|------|
| Classic Amber (default) | Dark housing, amber characters |
| Green Phosphor | Terminal green on black |
| White / Minimal | Light background, dark characters |

## Sharing

Compare daily token usage with friends anywhere in the world:

1. **macOS app:** Open Preferences > Sharing. **TUI:** Press `s` to open the sharing panel.
2. Enter a display name (up to 7 characters) and register
3. Copy your share link (e.g. `https://tokenbox.club/share/A3KX9F`) and send it to a friend
4. They paste your code/link in their Add Friend field
5. The bottom rows rotate through each friend's today count

Your token count pushes to the cloud every 60 seconds with per-model breakdown. Friends' counts refresh automatically. Each person's display respects their own model filter — switch between Opus/Sonnet/Haiku and both your count and friends' counts update. Only display name and output token counts are shared — never file paths, project names, or conversation content.

## Architecture

### macOS (Swift/SwiftUI)
```
Sources/
├── App/           # SwiftUI lifecycle, AppDelegate
├── Models/        # TokenDataStore, Database (SQLite), UsageRecord
├── Services/      # JSONLWatcher, LiveFileWatcher
├── Sharing/       # Cloud sharing client, SharingManager
└── Views/
    ├── SplitFlap/ # Core animation engine
    └── ...        # Settings, Dashboard, MenuBar
skill/             # Claude Code skill (Node.js)
hooks/             # statusLine relay script (bash)
cloud/             # Cloud Functions for sharing (Node.js, GCP)
```

### Terminal UI (Node.js)
```
tui/
├── index.mjs      # Entry point
├── app.mjs        # Orchestrator
└── lib/           # Display engine, data pipeline, sharing, settings
```

## Uninstall

```bash
tokenbox uninstall
```

Keep your token history for a clean reinstall:

```bash
tokenbox uninstall --keep-data
```

Removes: Claude Code hook, skill, CLI command, `~/.tokenbox/`, app data, and preferences. Your `settings.json` is backed up before modification.

## Development

### macOS
```bash
swift build                          # Debug build
swift build -c release               # Release build
swift test                           # Run all tests
node skill/collect.mjs --summary     # Test skill manually
```

### Terminal UI
```bash
cd tui && node index.mjs              # Launch TUI
cd tui && node index.mjs --theme green-phosphor  # With theme
```

## License

Private repository.

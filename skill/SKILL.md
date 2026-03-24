---
name: tokenbox
description: >
  Show your TokenBox usage stats — token counts, costs, and trends.
  Triggers on: "token stats", "how much have I spent", "usage report",
  "tokenbox", "token usage", "how many tokens".
---

# TokenBox Stats

When the user asks about token usage, run the collection script.
Do NOT parse JSONL files directly — that wastes context tokens.

## Steps

1. Run: `node ~/.claude/skills/tokenbox/collect.mjs --summary`
2. The script reads local JSONL files, aggregates, and prints a compact summary
3. Present the summary to the user in a readable format

## Example Output

Present as a clean, compact report:
- Today: 1.2M tokens ($14.30 est.) across 8 sessions
- This week: 6.8M tokens ($82.10 est.)
- Top model: claude-sonnet-4-6 (78% of tokens)
- Cache efficiency: 91%
- Streak: 12 days consecutive usage

## JSON Mode

For programmatic use: `node ~/.claude/skills/tokenbox/collect.mjs --json`

## Import Only

To import without generating a report: `node ~/.claude/skills/tokenbox/collect.mjs --import-only`

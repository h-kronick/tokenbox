#!/usr/bin/env node
// TokenBox collect.mjs — Main aggregation script
// Reads JSONL session logs, writes to SQLite, outputs summary
// Usage: node collect.mjs --summary | --json | --import-only

import { parseAll } from './lib/jsonl-parser.mjs';
import { getDb, insertEvents, rebuildDailySummary, getSummary, getStreak, closeDb } from './lib/db.mjs';
import { estimateCost } from './lib/pricing.mjs';

const args = process.argv.slice(2);
const mode = args.includes('--json') ? 'json' : args.includes('--import-only') ? 'import' : 'summary';

async function main() {
  // Initialize DB
  getDb();

  // 1. Parse all JSONL files
  const events = await parseAll();

  // 2. Compute costs for events that don't have one
  for (const event of events) {
    if (event.cost_usd == null) {
      event.cost_usd = estimateCost(event);
    }
  }

  // 3. Insert into SQLite (deduplication via UNIQUE constraint)
  const inserted = insertEvents(events);

  // 4. Rebuild daily summaries
  rebuildDailySummary();

  if (mode === 'import') {
    console.log(`Imported ${inserted} JSONL events.`);
    closeDb();
    return;
  }

  // 5. Generate summary
  // Use local timezone for date boundaries (matches Swift app's Calendar.current.startOfDay)
  const localDate = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  const today = localDate(new Date());
  const weekAgo = localDate(new Date(Date.now() - 7 * 86400000));
  const monthAgo = localDate(new Date(Date.now() - 30 * 86400000));

  const todayStats = getSummary(today, today);
  const weekStats = getSummary(weekAgo, today);
  const monthStats = getSummary(monthAgo, today);
  const streak = getStreak();

  if (mode === 'json') {
    console.log(JSON.stringify({
      today: todayStats,
      week: weekStats,
      month: monthStats,
      streak,
      imported: { jsonl: inserted },
    }, null, 2));
    closeDb();
    return;
  }

  // Summary mode — human-readable output
  console.log(formatSummary({ todayStats, weekStats, monthStats, streak, inserted }));
  closeDb();
}

function formatTokens(n) {
  if (n >= 1_000_000_000) return `${(n / 1_000_000_000).toFixed(1)}B`;
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
  return `${n}`;
}

function formatCost(c) {
  if (c == null) return 'N/A';
  return `$${c.toFixed(2)}`;
}

function formatSummary({ todayStats, weekStats, monthStats, streak, inserted }) {
  const lines = [];
  lines.push(`Today: ${formatTokens(todayStats.total_tokens)} tokens (${formatCost(todayStats.total_cost)} est.) across ${todayStats.session_count} sessions`);
  lines.push(`This week: ${formatTokens(weekStats.total_tokens)} tokens (${formatCost(weekStats.total_cost)} est.)`);
  lines.push(`This month: ${formatTokens(monthStats.total_tokens)} tokens (${formatCost(monthStats.total_cost)} est.)`);

  if (weekStats.by_model.length > 0) {
    const top = weekStats.by_model[0];
    const pct = weekStats.total_tokens > 0
      ? Math.round((top.tokens / weekStats.total_tokens) * 100)
      : 0;
    lines.push(`Top model: ${top.model} (${pct}% of tokens)`);
  }

  lines.push(`Cache efficiency: ${Math.round(weekStats.cache_efficiency * 100)}%`);
  lines.push(`Streak: ${streak} day${streak !== 1 ? 's' : ''} consecutive usage`);

  if (inserted > 0) {
    lines.push(`(Imported ${inserted} JSONL events)`);
  }

  return lines.join('\n');
}

main().catch((err) => {
  console.error(`TokenBox error: ${err.message}`);
  closeDb();
  process.exit(1);
});

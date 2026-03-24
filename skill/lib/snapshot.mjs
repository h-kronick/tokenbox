// Snapshot generation for sharing — creates signed aggregate data blobs
// Only shares aggregate stats, never file paths, project names, or content

import { getSummary } from './db.mjs';

/**
 * Generate a snapshot object for a given period.
 * The snapshot contains only aggregate data — no PII, no paths, no content.
 * @param {object} options
 * @param {string} options.displayName - Your display name
 * @param {string} options.publicKey - Base64url-encoded Ed25519 public key
 * @param {string} options.scopeId - Scope ID for this friend relationship
 * @param {string} options.from - Period start YYYY-MM-DD
 * @param {string} options.to - Period end YYYY-MM-DD
 * @returns {object} Unsigned snapshot object
 */
export function generateSnapshot({ displayName, publicKey, scopeId, from, to }) {
  const summary = getSummary(from, to);

  const models = {};
  for (const m of summary.by_model) {
    models[m.model] = { tokens: m.tokens };
  }

  // Find peak day
  let peak = { date: from, tokens: 0 };
  for (const d of summary.by_day) {
    if (d.tokens > peak.tokens) {
      peak = { date: d.date, tokens: d.tokens };
    }
  }

  const dailyAvg =
    summary.by_day.length > 0
      ? Math.round(summary.total_tokens / summary.by_day.length)
      : 0;

  return {
    v: 1,
    from: {
      name: displayName,
      pub: publicKey,
    },
    scope: scopeId,
    generated: new Date().toISOString(),
    period: { from, to },
    data: {
      total_tokens: summary.total_tokens,
      cost_est_usd: summary.total_cost ? Math.round(summary.total_cost * 100) / 100 : null,
      models,
      daily_avg: dailyAvg,
      peak,
      cache_eff: summary.cache_efficiency,
      sessions: summary.session_count,
    },
  };
}

/**
 * Serialize a snapshot to its canonical JSON form for signing.
 * Keys are sorted to ensure deterministic output.
 * @param {object} snapshot
 * @returns {string}
 */
export function canonicalize(snapshot) {
  // Recursively sort all keys, not just top-level
  function sortKeys(obj) {
    if (obj === null || typeof obj !== 'object') return obj;
    if (Array.isArray(obj)) return obj.map(sortKeys);
    const sorted = {};
    for (const key of Object.keys(obj).sort()) {
      sorted[key] = sortKeys(obj[key]);
    }
    return sorted;
  }
  return JSON.stringify(sortKeys(snapshot));
}

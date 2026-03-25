// Token display formatting — port of Swift AppState.formatTokens()
// All outputs are exactly 6 characters, right-aligned, space-padded on left.

/**
 * Format token count for the 6-module split-flap display.
 * Adaptive precision: 2 decimals when it fits, 1 when it doesn't.
 * @param {number} n - Token count
 * @returns {string} Exactly 6 characters, right-aligned
 */
export function formatTokens(n) {
  let raw;
  if (n < 1000) {
    raw = String(Math.round(n));
  } else if (n < 99_995) {
    raw = (n / 1_000).toFixed(2) + 'K';
  } else if (n < 999_950) {
    raw = (n / 1_000).toFixed(1) + 'K';
  } else if (n < 99_995_000) {
    raw = (n / 1_000_000).toFixed(2) + 'M';
  } else if (n < 999_950_000) {
    raw = (n / 1_000_000).toFixed(1) + 'M';
  } else if (n < 99_995_000_000) {
    raw = (n / 1_000_000_000).toFixed(2) + 'B';
  } else {
    raw = (n / 1_000_000_000).toFixed(1) + 'B';
  }
  // Right-align to 6 characters
  if (raw.length < 6) {
    return ' '.repeat(6 - raw.length) + raw;
  }
  return raw.slice(0, 6);
}

/**
 * Compact format for tray/menu bar — no padding.
 * @param {number} n - Token count
 * @returns {string} e.g. "197.19K"
 */
export function formatMenuBarTokens(n) {
  if (n < 1000) return String(Math.round(n));
  if (n < 999_995) return (n / 1_000).toFixed(2) + 'K';
  if (n < 999_995_000) return (n / 1_000_000).toFixed(2) + 'M';
  return (n / 1_000_000_000).toFixed(2) + 'B';
}

/**
 * Compact format for settings breakdowns — 1 decimal place.
 * @param {number} n - Token count
 * @returns {string} e.g. "45.3K"
 */
export function formatCompactTokens(n) {
  if (n < 1000) return String(n);
  if (n < 1_000_000) return (n / 1_000).toFixed(1) + 'K';
  if (n < 1_000_000_000) return (n / 1_000_000).toFixed(1) + 'M';
  return (n / 1_000_000_000).toFixed(1) + 'B';
}

/**
 * Format model ID to short display name.
 * @param {string} model - Full model ID
 * @returns {string} Short uppercase name
 */
export function formatModelShort(model) {
  if (model.includes('opus')) return 'OPUS';
  if (model.includes('sonnet')) return 'SONNET';
  if (model.includes('haiku')) return 'HAIKU';
  return model.slice(0, 6).toUpperCase();
}

/**
 * Format model ID to capitalized display name.
 * @param {string} model - Full model ID
 * @returns {string} e.g. "Opus", "Sonnet"
 */
export function formatModelName(model) {
  if (model.includes('opus')) return 'Opus';
  if (model.includes('sonnet')) return 'Sonnet';
  if (model.includes('haiku')) return 'Haiku';
  const parts = model.split('-');
  return parts[parts.length - 1] || model;
}

/**
 * Compact relative time string from ISO 8601 date.
 * @param {string} isoString - ISO 8601 timestamp
 * @returns {string|null} e.g. "3s ago", "5m ago", "2h ago", "1d ago"
 */
export function timeAgo(isoString) {
  if (!isoString) return null;
  const date = new Date(isoString);
  if (isNaN(date.getTime())) return null;

  const seconds = Math.floor((Date.now() - date.getTime()) / 1000);
  if (seconds < 0) return 'now';
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  return `${days}d ago`;
}

/**
 * Calculate time remaining until PST/PDT midnight (America/Los_Angeles).
 * @returns {string} e.g. "resets in 5h 23m"
 */
export function timeUntilReset() {
  const now = new Date();
  // Get current time in PST/PDT (America/Los_Angeles)
  const pstParts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/Los_Angeles',
    hour: 'numeric', minute: 'numeric', second: 'numeric',
    hour12: false,
  }).formatToParts(now);
  const h = parseInt(pstParts.find(p => p.type === 'hour').value, 10);
  const m = parseInt(pstParts.find(p => p.type === 'minute').value, 10);
  const s = parseInt(pstParts.find(p => p.type === 'second').value, 10);
  const secondsUntilMidnight = (24 * 3600) - (h * 3600 + m * 60 + s);
  const hours = Math.floor(secondsUntilMidnight / 3600);
  const minutes = Math.floor((secondsUntilMidnight % 3600) / 60);
  if (hours === 0 && minutes === 0) return 'resets in <1m';
  if (hours === 0) return `resets in ${minutes}m`;
  return `resets in ${hours}h ${minutes}m`;
}

/**
 * Get the current date string in PST/PDT (America/Los_Angeles).
 * @returns {string} e.g. "2026-03-25"
 */
export function currentPSTDate() {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Los_Angeles',
    year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(new Date());
}

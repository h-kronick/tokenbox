#!/usr/bin/env node
// TokenBox Status Relay — cross-platform Node.js hook script
// Receives Claude Code Status JSON on stdin, writes to live.json + events.jsonl
// Must complete in <10ms — no network calls, no heavy processing
// Uses only Node.js built-in modules (no npm dependencies)

import { readFileSync, writeFileSync, appendFileSync, renameSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { randomBytes } from 'node:crypto';

try {
  // Platform-aware data directory
  const dataDir = process.platform === 'win32'
    ? join(process.env.APPDATA || join(homedir(), 'AppData', 'Roaming'), 'TokenBox')
    : join(homedir(), 'Library', 'Application Support', 'TokenBox');

  // Ensure data directory exists
  mkdirSync(dataDir, { recursive: true });

  // Read stdin (Claude Code pipes Status JSON)
  let input;
  try {
    input = readFileSync(0, 'utf8');
  } catch {
    process.exit(0); // stdin not available or empty — exit silently
  }

  if (!input || !input.trim()) {
    process.exit(0); // empty stdin — nothing to do
  }

  let status;
  try {
    status = JSON.parse(input);
  } catch {
    process.exit(0); // malformed JSON — exit silently
  }

  if (!status || typeof status !== 'object') {
    process.exit(0);
  }

  // Extract fields (matching bash version's jq extraction paths)
  const sessionId = status.session_id || '';
  const model = status.model?.id || status.model?.api_model_id || 'unknown';
  const cost = status.cost?.total_cost_usd || 0;
  const inputTokens = status.context_window?.current_usage?.input_tokens || 0;
  const outputTokens = status.context_window?.current_usage?.output_tokens || 0;
  const cacheWrite = status.context_window?.current_usage?.cache_creation_input_tokens || 0;
  const cacheRead = status.context_window?.current_usage?.cache_read_input_tokens || 0;

  // Use local timezone ISO string (matches Swift app's Calendar.current.startOfDay)
  const now = new Date();
  const tzOffset = -now.getTimezoneOffset();
  const tzSign = tzOffset >= 0 ? '+' : '-';
  const tzHours = String(Math.floor(Math.abs(tzOffset) / 60)).padStart(2, '0');
  const tzMins = String(Math.abs(tzOffset) % 60).padStart(2, '0');
  const timestamp = now.getFullYear()
    + '-' + String(now.getMonth() + 1).padStart(2, '0')
    + '-' + String(now.getDate()).padStart(2, '0')
    + 'T' + String(now.getHours()).padStart(2, '0')
    + ':' + String(now.getMinutes()).padStart(2, '0')
    + ':' + String(now.getSeconds()).padStart(2, '0')
    + tzSign + tzHours + tzMins;

  // Build compact JSON payload (single line for JSONL compatibility)
  const payload = JSON.stringify({
    ts: timestamp,
    sid: sessionId,
    model,
    cost,
    in: inputTokens,
    out: outputTokens,
    cw: cacheWrite,
    cr: cacheRead,
  });

  // Atomic write to live.json (temp file + rename in same directory)
  const tmpFile = join(dataDir, `live.${randomBytes(4).toString('hex')}.json`);
  writeFileSync(tmpFile, payload, 'utf8');
  renameSync(tmpFile, join(dataDir, 'live.json'));

  // Append to event log for batch import
  appendFileSync(join(dataDir, 'events.jsonl'), payload + '\n', 'utf8');
} catch {
  // Exit 0 even on error to not break Claude Code
  // Hook failures must be silent
}

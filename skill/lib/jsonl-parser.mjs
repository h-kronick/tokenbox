// JSONL parser for Claude Code session logs
// Reads ~/.claude/projects/<project>/<session>.jsonl files
// Extracts token usage events from conversation data

import { readdir, readFile, stat } from 'node:fs/promises';
import { join, basename, dirname } from 'node:path';
import { homedir } from 'node:os';
import { normalizeModelId } from './pricing.mjs';

const CLAUDE_PROJECTS_DIR = join(homedir(), '.claude', 'projects');

/**
 * Parse a single JSONL line into a token event, or null if not a usage event.
 * Claude Code JSONL lines have varying formats — we look for assistant responses
 * that contain usage metadata.
 * @param {string} line
 * @param {string} sessionId
 * @param {string} project
 * @returns {object|null}
 */
export function parseLine(line, sessionId, project) {
  if (!line.trim()) return null;

  let obj;
  try {
    obj = JSON.parse(line);
  } catch {
    return null; // Skip corrupted lines per spec
  }

  // Skip intermediate streaming events for DB import — only count completed messages.
  // Intermediate events have stop_reason=null and would cause double/triple counting.
  if (obj.message && !obj.message.stop_reason) return null;

  // Look for usage data in the message object
  // Claude Code JSONL format has 'type' and 'message' or 'result' fields
  const usage = extractUsage(obj);
  if (!usage) return null;

  const model = normalizeModelId(
    obj.model || obj.message?.model || usage.model || 'unknown'
  );

  return {
    timestamp: obj.timestamp || obj.createdAt || new Date().toISOString(),
    source: 'claude_code',
    session_id: sessionId,
    project,
    model,
    input_tokens: usage.input_tokens || 0,
    output_tokens: usage.output_tokens || 0,
    cache_create: usage.cache_creation_input_tokens || 0,
    cache_read: usage.cache_read_input_tokens || 0,
  };
}

/**
 * Extract usage data from a JSONL object.
 * Handles multiple Claude Code JSONL formats.
 */
function extractUsage(obj) {
  // Format 1: Direct usage field
  if (obj.usage) return obj.usage;

  // Format 2: message.usage
  if (obj.message?.usage) return obj.message.usage;

  // Format 3: result.usage
  if (obj.result?.usage) return obj.result.usage;

  // Format 4: Nested in response
  if (obj.response?.usage) return obj.response.usage;

  // Format 5: costInfo with token fields at top level
  if (obj.costInfo) {
    return {
      input_tokens: obj.costInfo.inputTokens || 0,
      output_tokens: obj.costInfo.outputTokens || 0,
      cache_creation_input_tokens: obj.costInfo.cacheCreationInputTokens || 0,
      cache_read_input_tokens: obj.costInfo.cacheReadInputTokens || 0,
      model: obj.costInfo.modelId,
    };
  }

  return null;
}

/**
 * Parse a complete JSONL file and return token events.
 * @param {string} filePath
 * @returns {Promise<object[]>}
 */
export async function parseFile(filePath) {
  const content = await readFile(filePath, 'utf-8');
  const sessionId = basename(filePath, '.jsonl');
  const project = basename(dirname(filePath));
  const events = [];

  for (const line of content.split('\n')) {
    const event = parseLine(line, sessionId, project);
    if (event) events.push(event);
  }

  return events;
}

/**
 * Discover all JSONL files under ~/.claude/projects/
 * @returns {Promise<string[]>} Array of file paths
 */
export async function discoverFiles() {
  const files = [];
  try {
    const projects = await readdir(CLAUDE_PROJECTS_DIR);
    for (const project of projects) {
      const projectDir = join(CLAUDE_PROJECTS_DIR, project);
      const projectStat = await stat(projectDir).catch(() => null);
      if (!projectStat?.isDirectory()) continue;

      const entries = await readdir(projectDir).catch(() => []);
      for (const entry of entries) {
        if (entry.endsWith('.jsonl')) {
          files.push(join(projectDir, entry));
        }
      }
    }
  } catch {
    // ~/.claude/projects/ doesn't exist yet — that's fine
  }
  return files;
}

/**
 * Parse all discoverable JSONL files and return all token events.
 * @returns {Promise<object[]>}
 */
export async function parseAll() {
  const files = await discoverFiles();
  const allEvents = [];

  for (const file of files) {
    try {
      const events = await parseFile(file);
      allEvents.push(...events);
    } catch {
      // Skip files we can't read
    }
  }

  return allEvents;
}

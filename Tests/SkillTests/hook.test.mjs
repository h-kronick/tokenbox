import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execSync } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir, homedir } from 'node:os';

const HOOK_PATH = join(process.cwd(), 'hooks', 'status-relay.sh');
const DEST_DIR = join(homedir(), 'Library', 'Application Support', 'TokenBox');

describe('status-relay.sh', () => {
  it('hook script exists and is executable', () => {
    assert.ok(existsSync(HOOK_PATH), 'status-relay.sh should exist');
    // Check executable bit
    const stat = execSync(`stat -f '%Lp' "${HOOK_PATH}"`).toString().trim();
    assert.ok(stat.includes('7') || stat.includes('5'), 'should be executable');
  });

  it('produces valid JSON in live.json', () => {
    const input = JSON.stringify({
      session_id: 'test-hook-123',
      model: { id: 'claude-sonnet-4-6', display_name: 'Sonnet' },
      cost: { total_cost_usd: 1.23 },
      context_window: {
        current_usage: {
          input_tokens: 5000,
          output_tokens: 2000,
          cache_creation_input_tokens: 1000,
          cache_read_input_tokens: 500,
        },
      },
    });

    execSync(`echo '${input.replace(/'/g, "'\\''")}' | "${HOOK_PATH}"`, {
      timeout: 5000,
    });

    const livePath = join(DEST_DIR, 'live.json');
    assert.ok(existsSync(livePath), 'live.json should exist');

    const content = readFileSync(livePath, 'utf-8');
    const parsed = JSON.parse(content);

    assert.equal(parsed.sid, 'test-hook-123');
    assert.equal(parsed.model, 'claude-sonnet-4-6');
    assert.equal(parsed.cost, 1.23);
    assert.equal(parsed.in, 5000);
    assert.equal(parsed.out, 2000);
    assert.equal(parsed.cw, 1000);
    assert.equal(parsed.cr, 500);
    assert.ok(parsed.ts, 'should have timestamp');
  });

  it('handles missing optional fields', () => {
    const input = JSON.stringify({
      session_id: 'test-minimal',
      model: { api_model_id: 'claude-haiku-4-5' },
      cost: {},
      context_window: {
        current_usage: {
          input_tokens: 100,
          output_tokens: 50,
        },
      },
    });

    execSync(`echo '${input.replace(/'/g, "'\\''")}' | "${HOOK_PATH}"`, {
      timeout: 5000,
    });

    const content = readFileSync(join(DEST_DIR, 'live.json'), 'utf-8');
    const parsed = JSON.parse(content);

    assert.equal(parsed.model, 'claude-haiku-4-5');
    assert.equal(parsed.cost, 0);
    assert.equal(parsed.cw, 0);
    assert.equal(parsed.cr, 0);
  });

  it('appends to events.jsonl', () => {
    const eventsPath = join(DEST_DIR, 'events.jsonl');
    assert.ok(existsSync(eventsPath), 'events.jsonl should exist');

    const lines = readFileSync(eventsPath, 'utf-8').trim().split('\n');
    assert.ok(lines.length >= 1, 'should have at least one event line');

    // Each line should be valid JSON
    for (const line of lines) {
      if (line.trim()) {
        assert.doesNotThrow(() => JSON.parse(line), `Line should be valid JSON: ${line.slice(0, 50)}`);
      }
    }
  });
});

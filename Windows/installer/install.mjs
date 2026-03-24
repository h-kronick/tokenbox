#!/usr/bin/env node
// TokenBox Cross-Platform Installer
// Sets up hook, creates directories, installs skill dependencies
// Works on both macOS and Windows

import { existsSync, mkdirSync, copyFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const isWindows = process.platform === 'win32';

const hookDir = join(homedir(), '.tokenbox', 'hooks');
const dataDir = isWindows
  ? join(process.env.APPDATA || join(homedir(), 'AppData', 'Roaming'), 'TokenBox')
  : join(homedir(), 'Library', 'Application Support', 'TokenBox');

console.log('=== TokenBox Installer ===\n');

// 1. Create directories
console.log('[1/4] Creating directories...');
mkdirSync(hookDir, { recursive: true });
mkdirSync(dataDir, { recursive: true });
console.log(`  Created ${hookDir}`);
console.log(`  Created ${dataDir}`);

// 2. Copy hook script
console.log('[2/4] Installing status relay hook...');
const hookSrc = join(__dirname, '..', 'hooks', 'status-relay.mjs');
if (!existsSync(hookSrc)) {
  console.error(`  ERROR: Cannot find hooks/status-relay.mjs relative to this script.`);
  console.error(`  Expected at: ${hookSrc}`);
  process.exit(1);
}
const hookDest = join(hookDir, 'status-relay.mjs');
copyFileSync(hookSrc, hookDest);
console.log(`  Installed ${hookDest}`);

// 3. Install Node.js dependencies
console.log('[3/4] Installing Node.js dependencies...');
try {
  const nodeVersion = execSync('node -v', { encoding: 'utf8' }).trim().replace('v', '');
  const major = parseInt(nodeVersion.split('.')[0], 10);
  if (major < 18) {
    console.warn(`  WARNING: Node.js >= 18 required, found v${nodeVersion}`);
  } else {
    console.log(`  Node.js v${nodeVersion} detected`);
  }
} catch {
  console.warn('  WARNING: Could not detect Node.js version.');
}

const skillDir = join(__dirname, '..', '..', 'skill');
if (existsSync(join(skillDir, 'package.json'))) {
  try {
    execSync('npm install --omit=dev', { cwd: skillDir, stdio: 'inherit' });
    console.log('  Dependencies installed');
  } catch {
    console.warn('  WARNING: npm install failed. You may need to run it manually.');
  }
} else {
  console.log('  Skipping skill deps (skill/package.json not found)');
}

// 4. Print hook configuration snippet
console.log('[4/4] Hook configuration\n');
console.log('  Add the following to your ~/.claude/settings.json to enable real-time tracking:\n');

const configSnippet = {
  statusLine: {
    type: 'command',
    command: 'node ~/.tokenbox/hooks/status-relay.mjs',
  },
};
console.log('  ' + JSON.stringify(configSnippet, null, 2).split('\n').join('\n  '));

console.log('\n  NOTE: This script does NOT modify settings.json automatically.');
console.log('  Please add the statusLine configuration manually or merge it with your existing settings.\n');
console.log('=== TokenBox installed successfully ===\n');

console.log('To verify the hook works, run:');
const testPayload = '{"session_id":"test","model":{"id":"claude-sonnet-4-6"},"cost":{"total_cost_usd":0},"context_window":{"current_usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}';
if (isWindows) {
  console.log(`  echo '${testPayload}' | node "${hookDest}"`);
  console.log(`  type "${join(dataDir, 'live.json')}"`);
} else {
  console.log(`  echo '${testPayload}' | node "${hookDest}"`);
  console.log(`  cat "${join(dataDir, 'live.json')}"`);
}

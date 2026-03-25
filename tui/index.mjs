#!/usr/bin/env node
// TokenBox TUI — cross-platform split-flap terminal display

import { main } from './app.mjs';

// Parse CLI args
const args = process.argv.slice(2);
const overrides = {};

for (let i = 0; i < args.length; i++) {
  switch (args[i]) {
    case '--theme':
      overrides.theme = args[++i];
      break;
    case '--model-filter':
      overrides.modelFilter = args[++i];
      break;
    case '--no-sound':
      overrides.soundEnabled = false;
      break;
    case '--help':
    case '-h':
      console.log('Usage: tokenbox-tui [options]');
      console.log('');
      console.log('Options:');
      console.log('  --theme <name>         classic-amber | green-phosphor | white-minimal');
      console.log('  --model-filter <model> opus | sonnet | haiku | all');
      console.log('  --no-sound             Disable sound effects');
      console.log('  -h, --help             Show this help');
      console.log('');
      console.log('Keyboard:');
      console.log('  s          Sharing overlay');
      console.log('  p          Preferences overlay');
      console.log('  r          Force refresh');
      console.log('  ←/→        Manual context rotation');
      console.log('  Escape     Close overlay');
      console.log('  q, Ctrl+C  Quit');
      process.exit(0);
  }
}

// SIGUSR1 — sent by `tokenbox update` to signal a clean restart
process.on('SIGUSR1', () => {
  try { process.stdout.write('\x1b[?1049l\x1b[?25h'); } catch {}
  console.log('\nTokenBox updated. Restart with: tokenbox tui');
  process.exit(0);
});

// Handle uncaught errors — restore terminal before crashing
process.on('uncaughtException', (err) => {
  // Try to restore terminal
  try { process.stdout.write('\x1b[?1049l\x1b[?25h'); } catch {}
  console.error('TokenBox TUI error:', err.message);
  process.exit(1);
});

process.on('unhandledRejection', (err) => {
  try { process.stdout.write('\x1b[?1049l\x1b[?25h'); } catch {}
  console.error('TokenBox TUI error:', err.message || err);
  process.exit(1);
});

main(overrides).catch((err) => {
  try { process.stdout.write('\x1b[?1049l\x1b[?25h'); } catch {}
  console.error('TokenBox TUI error:', err.message);
  process.exit(1);
});

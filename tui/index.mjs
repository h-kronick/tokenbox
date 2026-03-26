#!/usr/bin/env node
// TokenBox TUI — cross-platform split-flap terminal display

import { main } from './app.mjs';
import { SharingManager } from './lib/sharing.mjs';
import { DataManager } from './lib/data.mjs';
import { SettingsManager } from './lib/settings.mjs';

// Parse CLI args
const args = process.argv.slice(2);
const overrides = {};

// --- CLI subcommands (no TUI required) ---

async function cliLink(linkCode) {
  const settings = new SettingsManager();
  const data = new DataManager();
  const sharing = new SharingManager(data, settings);
  sharing.start();

  if (linkCode) {
    // Redeem a link code
    try {
      const result = await sharing.redeemLinkCode(linkCode);
      console.log(`✔ Device linked to account: ${result.displayName}`);
      console.log(`  Device ID: ${result.deviceId}`);
    } catch (err) {
      console.error(`✗ ${err.message}`);
      process.exit(1);
    }
  } else {
    // Generate a link code
    if (!sharing.isRegistered()) {
      console.error('✗ Not registered for sharing. Run tokenbox, then press [s] to register.');
      process.exit(1);
    }
    try {
      const code = await sharing.createLinkCode();
      console.log(`✔ Link code generated (expires in 15 minutes):\n`);
      console.log(`  ${code}\n`);
      console.log(`On your other device, run:`);
      console.log(`  tokenbox link ${code}`);
    } catch (err) {
      console.error(`✗ ${err.message}`);
      process.exit(1);
    }
  }

  sharing.stop();
  process.exit(0);
}

async function cliDevices() {
  const settings = new SettingsManager();
  const data = new DataManager();
  const sharing = new SharingManager(data, settings);
  sharing.start();

  if (!sharing.isRegistered()) {
    console.error('✗ Not registered for sharing.');
    process.exit(1);
  }

  const devices = sharing.getDevices();
  const myDeviceId = sharing.getDeviceId();

  if (devices.length === 0) {
    console.log('No linked devices. Use "tokenbox link" to link another device.');
  } else {
    console.log('Linked devices:\n');
    devices.forEach((d, i) => {
      const label = d.label || 'Device';
      const isMe = d.deviceId === myDeviceId ? ' (this device)' : '';
      const lastPush = d.lastPush ? ` — last push: ${d.lastPush.slice(0, 10)}` : '';
      console.log(`  ${i + 1}. ${label}${isMe}${lastPush}`);
      console.log(`     ID: ${d.deviceId}`);
    });
  }

  sharing.stop();
  process.exit(0);
}

async function cliUnlink(deviceId) {
  const settings = new SettingsManager();
  const data = new DataManager();
  const sharing = new SharingManager(data, settings);
  sharing.start();

  if (!sharing.isRegistered()) {
    console.error('✗ Not registered for sharing.');
    process.exit(1);
  }

  if (!deviceId) {
    console.error('Usage: tokenbox unlink <deviceId>');
    console.error('Run "tokenbox devices" to see device IDs.');
    process.exit(1);
  }

  try {
    await sharing.unlinkDevice(deviceId);
    console.log(`✔ Device ${deviceId.slice(0, 8)}... unlinked.`);
  } catch (err) {
    console.error(`✗ ${err.message}`);
    process.exit(1);
  }

  sharing.stop();
  process.exit(0);
}

// Check for subcommands before TUI arg parsing
const subcommand = args[0];
if (subcommand === 'link') {
  cliLink(args[1]);
} else if (subcommand === 'devices') {
  cliDevices();
} else if (subcommand === 'unlink') {
  cliUnlink(args[1]);
} else {
  // Standard TUI mode — parse options
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
        console.log('       tokenbox link [TB-XXX-...]    Generate or redeem a link code');
        console.log('       tokenbox devices              List linked devices');
        console.log('       tokenbox unlink <deviceId>    Unlink a device');
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
}

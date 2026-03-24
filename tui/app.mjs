// Orchestrator — wires Display, DataManager, SharingManager, SettingsManager together.

import blessed from 'blessed';
import { Display, THEMES } from './lib/display.mjs';
import { SplitFlapRow } from './lib/animation.mjs';
import { TOKEN_POSITION_SETS } from './lib/charsets.mjs';
import { formatTokens, formatModelName, timeUntilReset } from './lib/formatting.mjs';
import { DataManager } from './lib/data.mjs';
import { SharingManager } from './lib/sharing.mjs';
import { SettingsManager } from './lib/settings.mjs';

const MODEL_CYCLE = ['opus', 'sonnet', 'haiku', 'all'];
const PERIOD_CYCLE = ['today', 'week', 'month', 'allTime'];
const THEME_CYCLE = Object.keys(THEMES);
const SPEED_CYCLE = [0.5, 1.0, 1.5, 2.0];
const PERIOD_LABELS = { today: 'TODAY', week: 'THIS WEEK', month: 'THIS MONTH', allTime: 'ALL TIME' };

export async function main(overrides = {}) {
  // Init managers
  const settings = new SettingsManager();
  const data = new DataManager();
  const sharing = new SharingManager(data, settings);

  // Apply CLI overrides
  if (overrides.theme) settings.set('theme', overrides.theme);
  if (overrides.modelFilter) settings.set('modelFilter', overrides.modelFilter);
  if (overrides.soundEnabled === false) settings.set('soundEnabled', false);

  const s = settings.getAll();

  // Create blessed screen
  const screen = blessed.screen({
    smartCSR: true,
    title: 'TokenBox',
    fullUnicode: true,
    terminal: 'xterm-256color',
    warnings: false,
  });

  // Suppress Setulc terminfo error (blessed bug with modern terminals)
  if (screen.tput) {
    screen.tput.strings.Setulc = '';
  }

  // Create display
  const display = new Display(screen);
  display.setTheme(s.theme);
  display.setPinnedLabel(PERIOD_LABELS[s.pinnedPeriod] || 'TODAY', formatModelName(s.modelFilter), timeUntilReset());

  // Create animation rows
  const pinnedRow = new SplitFlapRow(TOKEN_POSITION_SETS);
  const contextRow = new SplitFlapRow(TOKEN_POSITION_SETS);

  // --- Data events ---

  data.on('pinned-change', ({ label, value, modelName, resetTime }) => {
    display.setPinnedLabel(label, modelName || formatModelName(s.modelFilter), resetTime || timeUntilReset());
    const formatted = formatTokens(value);
    pinnedRow.setTarget(formatted);
    pinnedRow.startAnimation((pos, ch) => display.renderFlap(0, pos, ch), s.animationSpeed);
  });

  data.on('context-change', ({ label, value, subtitle }) => {
    display.setContextLabel(label, subtitle);
    const formatted = formatTokens(value);
    contextRow.setTarget(formatted);
    contextRow.startAnimation((pos, ch) => display.renderFlap(1, pos, ch), s.animationSpeed);
  });

  data.on('live-update', (liveData) => {
    if (s.realtimeFlip && liveData.out) {
      data.addRealtimeDelta(liveData.out);
    }
  });

  // --- Sharing events ---

  sharing.on('friends-changed', (friends) => {
    data.setFriends(friends);
  });

  // --- Settings events ---

  settings.on('settings-changed', ({ key, value }) => {
    switch (key) {
      case 'theme':
        display.setTheme(value);
        break;
      case 'modelFilter':
        data.setModelFilter(value);
        break;
      case 'pinnedPeriod':
        data.setPinnedPeriod(value);
        break;
      case 'animationSpeed':
        s.animationSpeed = value;
        break;
      case 'realtimeFlip':
        s.realtimeFlip = value;
        break;
    }
    // Keep local cache in sync
    s[key] = value;
  });

  // --- Keyboard handling ---

  let activeOverlay = null;

  screen.key(['q'], () => shutdown());
  screen.key(['C-c'], () => shutdown());

  screen.key(['r'], () => {
    if (activeOverlay) return;
    data.refresh();
  });

  screen.key(['left'], () => {
    if (activeOverlay) return;
    data._contextIndex--;
    if (data._contextIndex < 0) data._contextIndex = 0;
    data._emitContextChange();
    // Restart rotation timer
    if (data._rotationTimer) clearInterval(data._rotationTimer);
    data._startContextRotation();
  });

  screen.key(['right'], () => {
    if (activeOverlay) return;
    data._contextIndex++;
    data._emitContextChange();
    if (data._rotationTimer) clearInterval(data._rotationTimer);
    data._startContextRotation();
  });

  screen.key(['escape'], () => {
    if (activeOverlay) {
      activeOverlay.destroy();
      activeOverlay = null;
      screen.render();
    }
  });

  screen.key(['s'], () => {
    if (activeOverlay) return;
    showSharingOverlay();
  });

  screen.key(['p'], () => {
    if (activeOverlay) return;
    showPrefsOverlay();
  });

  // --- Overlays ---

  function createOverlay(title, height) {
    const box = blessed.box({
      parent: screen,
      top: 'center',
      left: 'center',
      width: '60%',
      height: height || '60%',
      border: { type: 'line' },
      label: ` ${title} `,
      style: {
        border: { fg: 'yellow' },
        bg: 'black',
        fg: 'white',
      },
      tags: true,
      keys: true,
      vi: false,
      scrollable: true,
    });
    activeOverlay = box;
    return box;
  }

  function showSharingOverlay() {
    if (sharing.isRegistered()) {
      showRegisteredSharingOverlay();
    } else {
      showRegisterOverlay();
    }
  }

  function showRegisterOverlay() {
    const box = createOverlay('Share', 12);

    const prompt = blessed.textbox({
      parent: box,
      top: 2,
      left: 2,
      right: 2,
      height: 3,
      border: { type: 'line' },
      label: ' Display Name ',
      style: {
        border: { fg: 'white' },
        bg: 'black',
        fg: 'white',
      },
      inputOnFocus: true,
    });

    const info = blessed.box({
      parent: box,
      top: 0,
      left: 2,
      right: 2,
      height: 2,
      content: 'Enter a display name to share your stats:',
      style: { bg: 'black', fg: 'white' },
    });

    const status = blessed.box({
      parent: box,
      top: 6,
      left: 2,
      right: 2,
      height: 2,
      content: '',
      style: { bg: 'black', fg: 'yellow' },
    });

    prompt.focus();
    screen.render();

    prompt.on('submit', async (value) => {
      const name = (value || '').trim();
      if (!name) {
        status.setContent('Name cannot be empty');
        screen.render();
        prompt.focus();
        return;
      }

      status.setContent('Registering...');
      screen.render();

      try {
        const result = await sharing.register(name);
        box.destroy();
        activeOverlay = null;
        showRegisteredSharingOverlay();
      } catch (err) {
        status.setContent(`Error: ${err.message}`);
        screen.render();
        prompt.focus();
      }
    });

    prompt.on('cancel', () => {
      box.destroy();
      activeOverlay = null;
      screen.render();
    });
  }

  function showRegisteredSharingOverlay() {
    const code = sharing.getShareCode();
    const url = sharing.getShareURL();
    const friends = sharing.getFriends();

    let content = `Your share code: {bold}${code}{/bold}\n`;
    content += `URL: ${url}\n\n`;

    if (friends.length > 0) {
      content += `{bold}Friends:{/bold}\n`;
      friends.forEach((f, i) => {
        let nameDisplay = f.label || f.displayName;
        if (f.nickname) {
          nameDisplay = `${f.nickname} (${f.displayName})`;
        }
        content += `  ${i + 1}. ${nameDisplay} (${f.code}) — ${f.tokens} tokens\n`;
      });
      content += '\n';
    }

    content += '[a] Add friend  [d] Remove friend  [Esc] Close';

    const box = createOverlay('Sharing', Math.min(friends.length + 10, 20));
    box.setContent(content);
    screen.render();

    box.key(['a'], () => {
      showAddFriendPrompt(box);
    });

    box.key(['d'], () => {
      if (friends.length === 0) return;
      showRemoveFriendPrompt(box, friends);
    });

    box.focus();
  }

  function showAddFriendPrompt(parentBox) {
    const prompt = blessed.textbox({
      parent: parentBox,
      bottom: 1,
      left: 2,
      right: 2,
      height: 3,
      border: { type: 'line' },
      label: ' Code or URL ',
      style: {
        border: { fg: 'white' },
        bg: 'black',
        fg: 'white',
      },
      inputOnFocus: true,
    });

    prompt.focus();
    screen.render();

    prompt.on('submit', async (value) => {
      const input = (value || '').trim();
      if (!input) { prompt.destroy(); screen.render(); return; }

      try {
        const result = await sharing.addFriend(input);
        parentBox.destroy();
        activeOverlay = null;

        if (result && result.needsNickname) {
          showNicknamePrompt(result.code, result.displayName);
        } else {
          showRegisteredSharingOverlay();
        }
      } catch (err) {
        prompt.destroy();
        parentBox.setContent(parentBox.getContent() + `\n{red-fg}Error: ${err.message}{/red-fg}`);
        screen.render();
      }
    });

    prompt.on('cancel', () => {
      prompt.destroy();
      screen.render();
    });
  }

  function showNicknamePrompt(code, conflictingName) {
    const box = createOverlay('Nickname', 10);

    const info = blessed.box({
      parent: box,
      top: 0,
      left: 2,
      right: 2,
      height: 2,
      content: `You already have a friend named ${conflictingName}.\nEnter a nickname for this friend:`,
      style: { bg: 'black', fg: 'white' },
    });

    const prompt = blessed.textbox({
      parent: box,
      top: 3,
      left: 2,
      right: 2,
      height: 3,
      border: { type: 'line' },
      label: ' Nickname (1-7 chars) ',
      style: {
        border: { fg: 'white' },
        bg: 'black',
        fg: 'white',
      },
      inputOnFocus: true,
    });

    prompt.focus();
    screen.render();

    prompt.on('submit', (value) => {
      const nick = (value || '').trim();
      if (nick) {
        sharing.setNickname(code, nick);
      }
      box.destroy();
      activeOverlay = null;
      showRegisteredSharingOverlay();
    });

    prompt.on('cancel', () => {
      box.destroy();
      activeOverlay = null;
      showRegisteredSharingOverlay();
    });
  }

  function showRemoveFriendPrompt(parentBox, friends) {
    const prompt = blessed.textbox({
      parent: parentBox,
      bottom: 1,
      left: 2,
      right: 2,
      height: 3,
      border: { type: 'line' },
      label: ' Friend # to remove ',
      style: {
        border: { fg: 'white' },
        bg: 'black',
        fg: 'white',
      },
      inputOnFocus: true,
    });

    prompt.focus();
    screen.render();

    prompt.on('submit', (value) => {
      const idx = parseInt(value, 10) - 1;
      if (idx >= 0 && idx < friends.length) {
        sharing.removeFriend(friends[idx].code);
        parentBox.destroy();
        activeOverlay = null;
        showRegisteredSharingOverlay();
      } else {
        prompt.destroy();
        screen.render();
      }
    });

    prompt.on('cancel', () => {
      prompt.destroy();
      screen.render();
    });
  }

  function showPrefsOverlay() {
    const currentSettings = settings.getAll();

    const items = [
      { key: 'modelFilter', label: 'Model', cycle: MODEL_CYCLE },
      { key: 'pinnedPeriod', label: 'Pinned', cycle: PERIOD_CYCLE },
      { key: 'theme', label: 'Theme', cycle: THEME_CYCLE },
      { key: 'animationSpeed', label: 'Speed', cycle: SPEED_CYCLE, format: v => `${v}x` },
    ];

    let selected = 0;

    function renderPrefs() {
      let content = '{bold}Preferences{/bold}  (↑↓ navigate, Enter cycle, Esc close)\n\n';
      items.forEach((item, i) => {
        const val = item.format ? item.format(currentSettings[item.key]) : currentSettings[item.key];
        const prefix = i === selected ? ' ▸ ' : '   ';
        content += `${prefix}{bold}${item.label}:{/bold} ${val}\n`;
      });
      box.setContent(content);
      screen.render();
    }

    const box = createOverlay('Preferences', items.length + 6);

    box.key(['up', 'k'], () => {
      selected = (selected - 1 + items.length) % items.length;
      renderPrefs();
    });

    box.key(['down', 'j'], () => {
      selected = (selected + 1) % items.length;
      renderPrefs();
    });

    box.key(['enter', 'space'], () => {
      const item = items[selected];
      const cycle = item.cycle;
      const cur = currentSettings[item.key];
      const idx = cycle.indexOf(cur);
      const next = cycle[(idx + 1) % cycle.length];
      currentSettings[item.key] = next;
      settings.set(item.key, next);
      renderPrefs();
    });

    box.focus();
    renderPrefs();
  }

  // 60-second timer to update "resets in" time on pinned label
  const resetTimer = setInterval(() => {
    display.setPinnedLabel(
      PERIOD_LABELS[s.pinnedPeriod] || 'TODAY',
      formatModelName(s.modelFilter),
      timeUntilReset()
    );
    display.render();
  }, 60_000);

  function shutdown() {
    clearInterval(resetTimer);
    data.stop();
    sharing.stop();
    pinnedRow.stopAnimation();
    contextRow.stopAnimation();
    try { screen.destroy(); } catch {}
    process.exit(0);
  }

  // --- Start everything ---

  // Startup cascade — simulate display warming up
  display.render();

  await new Promise(resolve => {
    const randomChars = '0123456789';
    const randomTarget = Array(7).fill(0).map(() =>
      randomChars[Math.floor(Math.random() * randomChars.length)]
    ).join('');

    pinnedRow.setTarget(randomTarget);
    contextRow.setTarget(randomTarget);

    pinnedRow.startAnimation((pos, ch) => display.renderFlap(0, pos, ch), s.animationSpeed);
    contextRow.startAnimation((pos, ch) => display.renderFlap(1, pos, ch), s.animationSpeed);

    setTimeout(() => resolve(), 800);
  });

  data.start(s.modelFilter, s.pinnedPeriod);
  sharing.start();
}

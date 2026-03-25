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

  screen.key(['l'], () => {
    if (activeOverlay) return;
    showLeaderboardOverlay();
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

  // --- Leaderboard overlay ---

  // Persistent leaderboard rank — fetch periodically when opted in
  let leaderboardRankTimer = null;

  async function refreshLeaderboardRank() {
    if (!sharing.isLeaderboardOptIn()) return;
    const myUsername = sharing.getLeaderboardUsername();
    if (!myUsername) return;

    try {
      const today = new Date().toISOString().slice(0, 10);
      const model = s.modelFilter === 'all' ? 'opus' : s.modelFilter;
      const data = await sharing.getLeaderboard(today, model, 50);
      if (data && data.entries) {
        const me = data.entries.find(e => e.username && e.username.toLowerCase() === myUsername.toLowerCase());
        if (me) {
          display.setLeaderboardRank(me.rank, myUsername);
        } else {
          display.setLeaderboardRank(null);
        }
      }
    } catch {
      // Silent — don't clear rank on network error
    }
    display.render();
  }

  function startLeaderboardRankPolling() {
    if (leaderboardRankTimer) clearInterval(leaderboardRankTimer);
    if (sharing.isLeaderboardOptIn()) {
      refreshLeaderboardRank();
      leaderboardRankTimer = setInterval(refreshLeaderboardRank, 120_000);
    }
  }

  function formatCompactNum(n) {
    if (n < 1000) return String(n);
    if (n < 1_000_000) return (n / 1_000).toFixed(1).replace(/\.0$/, '') + 'K';
    if (n < 1_000_000_000) return (n / 1_000_000).toFixed(1).replace(/\.0$/, '') + 'M';
    return (n / 1_000_000_000).toFixed(1).replace(/\.0$/, '') + 'B';
  }

  function formatCommaNum(n) {
    return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  }

  function showLeaderboardOverlay() {
    // Guard: must be registered for sharing
    if (!sharing.isRegistered()) {
      const box = createOverlay('Leaderboard', 7);
      box.setContent(
        '\n  {yellow-fg}Not registered for sharing.{/yellow-fg}\n\n' +
        '  Press {bold}s{/bold} to register first.'
      );
      box.focus();
      screen.render();
      setTimeout(() => {
        if (activeOverlay === box) {
          box.destroy();
          activeOverlay = null;
          screen.render();
        }
      }, 2500);
      return;
    }

    if (sharing.isLeaderboardOptIn()) {
      showLeaderboardView();
    } else {
      showLeaderboardOptInStep1();
    }
  }

  function showLeaderboardOptInStep1() {
    const box = createOverlay('Join Leaderboard', 13);
    box.setContent(
      '\n  {yellow-fg}Step 1 of 3{/yellow-fg}\n\n' +
      '  Join the public daily leaderboard.\n' +
      '  Only your {bold}username{/bold} and {bold}daily output\n' +
      '  token count{/bold} are visible.\n\n' +
      '  All other Claude data stays private.\n\n' +
      '  {bold}[Enter]{/bold} Continue    {bold}[Esc]{/bold} Cancel'
    );
    box.focus();
    screen.render();

    box.key(['enter'], () => {
      box.destroy();
      activeOverlay = null;
      showLeaderboardOptInStep2();
    });
  }

  function showLeaderboardOptInStep2() {
    const box = createOverlay('Choose Username', 12);

    const header = blessed.box({
      parent: box,
      top: 0,
      left: 2,
      right: 2,
      height: 3,
      content: '  {yellow-fg}Step 2 of 3{/yellow-fg}\n\n  Choose a public username:',
      style: { bg: 'black', fg: 'white' },
      tags: true,
    });

    const prompt = blessed.textbox({
      parent: box,
      top: 4,
      left: 2,
      right: 2,
      height: 3,
      border: { type: 'line' },
      label: ' Username (3-15 chars, a-z 0-9 _) ',
      style: {
        border: { fg: 'yellow' },
        bg: 'black',
        fg: 'white',
      },
      inputOnFocus: true,
    });

    const status = blessed.box({
      parent: box,
      top: 8,
      left: 2,
      right: 2,
      height: 1,
      content: '',
      style: { bg: 'black', fg: 'red' },
      tags: true,
    });

    prompt.focus();
    screen.render();

    prompt.on('submit', (value) => {
      const username = (value || '').trim();
      if (!username || username.length < 3) {
        status.setContent('  {red-fg}Too short — minimum 3 characters{/red-fg}');
        screen.render();
        prompt.focus();
        return;
      }
      if (username.length > 15) {
        status.setContent('  {red-fg}Too long — maximum 15 characters{/red-fg}');
        screen.render();
        prompt.focus();
        return;
      }
      if (!/^[a-zA-Z0-9_]+$/.test(username)) {
        status.setContent('  {red-fg}Letters, numbers, and underscore only{/red-fg}');
        screen.render();
        prompt.focus();
        return;
      }
      box.destroy();
      activeOverlay = null;
      showLeaderboardOptInStep3(username);
    });

    prompt.on('cancel', () => {
      box.destroy();
      activeOverlay = null;
      screen.render();
    });
  }

  function showLeaderboardOptInStep3(username) {
    const box = createOverlay('Email Address', 12);

    const header = blessed.box({
      parent: box,
      top: 0,
      left: 2,
      right: 2,
      height: 3,
      content: '  {yellow-fg}Step 3 of 3{/yellow-fg}\n\n  Your email (private, never displayed):',
      style: { bg: 'black', fg: 'white' },
      tags: true,
    });

    const prompt = blessed.textbox({
      parent: box,
      top: 4,
      left: 2,
      right: 2,
      height: 3,
      border: { type: 'line' },
      label: ' Email ',
      style: {
        border: { fg: 'yellow' },
        bg: 'black',
        fg: 'white',
      },
      inputOnFocus: true,
    });

    const status = blessed.box({
      parent: box,
      top: 8,
      left: 2,
      right: 2,
      height: 1,
      content: '',
      style: { bg: 'black', fg: 'yellow' },
      tags: true,
    });

    prompt.focus();
    screen.render();

    prompt.on('submit', async (value) => {
      const email = (value || '').trim();
      if (!email || !/.+@.+\..+/.test(email)) {
        status.setContent('  {red-fg}Enter a valid email address{/red-fg}');
        screen.render();
        prompt.focus();
        return;
      }

      status.setContent('  {yellow-fg}Joining leaderboard...{/yellow-fg}');
      screen.render();

      try {
        await sharing.joinLeaderboard(username, email);
        box.destroy();
        activeOverlay = null;
        showLeaderboardSuccess(username);
      } catch (err) {
        status.setContent(`  {red-fg}${err.message}{/red-fg}`);
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

  function showLeaderboardSuccess(username) {
    const box = createOverlay('Leaderboard', 10);
    box.setContent(
      '\n  {green-fg}\u2714{/green-fg} {bold}You\'re on the board!{/bold}\n\n' +
      `  Username:  {bold}@${username}{/bold}\n` +
      `  Status:    {green-fg}Active{/green-fg}\n\n` +
      '  {bold}[Enter]{/bold} View leaderboard    {bold}[Esc]{/bold} Close'
    );
    box.focus();
    screen.render();

    // Start rank polling now that we're opted in
    startLeaderboardRankPolling();

    box.key(['enter'], () => {
      box.destroy();
      activeOverlay = null;
      showLeaderboardView();
    });
  }

  function showLeaderboardView() {
    const MODELS = ['opus', 'sonnet', 'haiku'];
    let currentModel = MODELS.indexOf(s.modelFilter !== 'all' ? s.modelFilter : 'opus');
    if (currentModel < 0) currentModel = 0;
    let currentDate = new Date().toISOString().slice(0, 10);
    let leaderboardData = null;
    let loading = true;
    let errorMsg = null;
    const myUsername = sharing.getLeaderboardUsername();

    const box = createOverlay('Leaderboard', '80%');
    box.focus();

    function renderBoard() {
      const todayStr = new Date().toISOString().slice(0, 10);
      const isToday = currentDate === todayStr;
      const liveTag = isToday ? '  {green-fg}[live]{/green-fg}' : '';

      // Model tabs with box-drawing separators
      const modelTabs = MODELS.map((m, i) => {
        const label = m.charAt(0).toUpperCase() + m.slice(1);
        return i === currentModel
          ? `{yellow-fg}{bold}${label}{/bold}{/yellow-fg}`
          : `{white-fg}${label}{/white-fg}`;
      }).join(' {white-fg}\u2502{/white-fg} ');

      // Date display
      const dateLabel = isToday ? 'Today' : currentDate;

      let content = '';
      content += `  ${modelTabs}${liveTag}\n`;
      content += `  {white-fg}${dateLabel}{/white-fg}\n`;
      content += '  {white-fg}\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500{/white-fg}\n';

      if (loading) {
        content += '\n  {yellow-fg}\u25cf{/yellow-fg} Loading...\n';
      } else if (errorMsg) {
        content += `\n  {red-fg}\u2716 ${errorMsg}{/red-fg}\n`;
      } else if (!leaderboardData || !leaderboardData.entries || leaderboardData.entries.length === 0) {
        content += '\n  {yellow-fg}No entries yet \u2014 be the first!{/yellow-fg}\n';
      } else {
        const entries = leaderboardData.entries;
        const myIdx = myUsername ? entries.findIndex(e => e.username && e.username.toLowerCase() === myUsername.toLowerCase()) : -1;

        // Show top entries, then separator + own entry if not in top
        const topCount = Math.min(entries.length, 20);
        let shownMyEntry = false;

        for (let i = 0; i < topCount; i++) {
          const entry = entries[i];
          const isMe = myUsername && entry.username && entry.username.toLowerCase() === myUsername.toLowerCase();
          if (isMe) shownMyEntry = true;
          content += formatLeaderboardEntry(entry, isMe);
        }

        // If user is not in the visible top, show separator + their entry
        if (myIdx >= topCount && !shownMyEntry) {
          content += '  {white-fg}\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500{/white-fg}\n';
          content += formatLeaderboardEntry(entries[myIdx], true);
        }
      }

      content += '\n  {bold}[\u2190/\u2192]{/bold} Day  {bold}[m]{/bold} Model  {bold}[Esc]{/bold} Close';

      box.setContent(content);
      screen.render();
    }

    function formatLeaderboardEntry(entry, isMe) {
      const rank = String(entry.rank).padStart(3);
      const name = (entry.username || '?').padEnd(18);
      const tokStr = formatCommaNum(entry.tokens || 0);
      const compact = formatCompactNum(entry.tokens || 0);
      // Right-align token count in a 12-char field
      const tokenDisplay = tokStr.padStart(12);

      if (isMe) {
        return `  {yellow-fg}{bold}#${rank}  ${name} ${tokenDisplay}{/bold}{/yellow-fg}  {yellow-fg}\u25c0{/yellow-fg}\n`;
      }
      return `  {white-fg} #${rank}  ${name} ${tokenDisplay}{/white-fg}\n`;
    }

    async function fetchData() {
      loading = true;
      errorMsg = null;
      renderBoard();

      try {
        leaderboardData = await sharing.getLeaderboard(currentDate, MODELS[currentModel], 50);
      } catch (err) {
        errorMsg = 'Leaderboard unavailable';
        leaderboardData = null;
      }
      loading = false;
      renderBoard();
    }

    box.key(['m'], () => {
      currentModel = (currentModel + 1) % MODELS.length;
      fetchData();
    });

    box.key(['left'], () => {
      const d = new Date(currentDate + 'T12:00:00');
      d.setDate(d.getDate() - 1);
      currentDate = d.toISOString().slice(0, 10);
      fetchData();
    });

    box.key(['right'], () => {
      const today = new Date().toISOString().slice(0, 10);
      if (currentDate >= today) return;
      const d = new Date(currentDate + 'T12:00:00');
      d.setDate(d.getDate() + 1);
      currentDate = d.toISOString().slice(0, 10);
      fetchData();
    });

    fetchData();
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
    if (leaderboardRankTimer) clearInterval(leaderboardRankTimer);
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
    const randomTarget = Array(6).fill(0).map(() =>
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

  // Start leaderboard rank polling if opted in
  startLeaderboardRankPolling();
}

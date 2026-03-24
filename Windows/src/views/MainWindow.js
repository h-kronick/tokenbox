// Main window controller — wires display, state, stores, and events together.
// Port of MainWindowView.swift for Tauri.

import { SplitFlapDisplay } from '../components/SplitFlapDisplay.js';
import { appState } from '../stores/appState.js';
import { tokenStore } from '../stores/tokenStore.js';
import { sharingStore } from '../stores/sharing.js';
import { menuBarState } from '../stores/menuBarState.js';
import { formatTokens, timeUntilReset } from '../lib/formatting.js';

const { invoke } = window.__TAURI__.core;
const { listen, emit } = window.__TAURI__.event;

// ─── Display references ─────────────────────────────────────────────
let splitFlapDisplay = null;
let flapSoundEngine = null;

/**
 * Set the FlapSoundEngine instance.
 */
export function setSoundEngine(engine) {
  flapSoundEngine = engine;
}

// ─── Initialization ──────────────────────────────────────────────────

let resetCountdownTimer = null;
let initialized = false;

export async function initMainWindow(container) {
  if (initialized) return;
  initialized = true;

  // Create the display
  splitFlapDisplay = new SplitFlapDisplay(container, {
    theme: 'classic-amber',
    soundEnabled: true,
    animationSpeed: 1.0,
  });
  flapSoundEngine = splitFlapDisplay.soundEngine || null;
  window.__tokenbox = { display: splitFlapDisplay };

  // Wire appState to tokenStore
  appState.setTokenStore(tokenStore);

  // Load initial data
  await tokenStore.refresh();
  await loadSettings();
  await loadFriends();

  // Start systems
  appState.startContextRotation();
  menuBarState.start(tokenStore);

  // Wire store changes to display updates
  tokenStore.onChange(() => {
    appState.refreshValues();
    updateDisplay();
  });

  appState.onChange(() => {
    updateDisplay();
  });

  sharingStore.onChange(() => {
    appState.setFriends(buildFriendsList());
    appState.refreshContext();
  });

  // Listen for settings changes from Settings window
  await listen('display-settings-changed', (event) => {
    const p = event.payload || {};
    if (p.pinnedDisplay !== undefined) appState.pinnedDisplay = p.pinnedDisplay;
    if (p.modelFilter !== undefined) {
      appState.modelFilter = p.modelFilter;
      tokenStore.setModelFilter(p.modelFilter);
    }
    if (p.realtimeFlipDisplay !== undefined) appState.realtimeFlipDisplay = p.realtimeFlipDisplay;
    if (p.theme !== undefined) applyTheme(p.theme);
    if (p.soundEnabled !== undefined && splitFlapDisplay) splitFlapDisplay.setSoundEnabled(p.soundEnabled);
    if (p.soundVolume !== undefined && splitFlapDisplay) splitFlapDisplay.setSoundVolume(p.soundVolume);
    if (p.animationSpeed !== undefined) applyAnimationSpeed(p.animationSpeed);

    menuBarState.setPinnedDisplay(appState.pinnedDisplay);
    appState.refreshContext();
    updateDisplay();
  });

  // Preview sound from Settings
  await listen('preview-sound', () => {
    if (flapSoundEngine) flapSoundEngine.playFlap();
  });

  // Friends changed
  await listen('friends-changed', async () => {
    await loadFriends();
    appState.setFriends(buildFriendsList());
    appState.refreshContext();
  });

  // Push tokens on count changes
  tokenStore.onChange(() => {
    if (sharingStore.sharingEnabled) {
      sharingStore.pushMyTokens({
        todayTokens: tokenStore.todayTokens,
        todayByModel: tokenStore.todayByModel,
        weekByModel: tokenStore.weekByModel,
        monthByModel: tokenStore.monthByModel,
        allTimeByModel: tokenStore.allTimeByModel,
      });
    }
  });

  // Initial push if sharing enabled
  if (sharingStore.sharingEnabled) {
    sharingStore.pushMyTokens({
      todayTokens: tokenStore.todayTokens,
      todayByModel: tokenStore.todayByModel,
      weekByModel: tokenStore.weekByModel,
      monthByModel: tokenStore.monthByModel,
      allTimeByModel: tokenStore.allTimeByModel,
    });
  }

  // Start "resets in Xh Ym" countdown timer (updates every 60s)
  startResetCountdown();

  // Reduced motion preference
  applyReducedMotion();

  // Initial display update
  appState.refreshContext();
  updateDisplay();
}

// ─── Settings Loading ────────────────────────────────────────────────

async function loadSettings() {
  try {
    const s = await invoke('get_settings');
    appState.pinnedDisplay = s.pinnedDisplay || 'today';
    appState.modelFilter = s.modelFilter || 'opus';
    appState.realtimeFlipDisplay = s.realtimeFlipDisplay !== false;
    menuBarState.setPinnedDisplay(appState.pinnedDisplay);

    if (s.theme) applyTheme(s.theme);
    if (s.animationSpeed) applyAnimationSpeed(s.animationSpeed);
    if (splitFlapDisplay) {
      splitFlapDisplay.setSoundEnabled(s.soundEnabled === true);
      splitFlapDisplay.setSoundVolume(s.soundVolume || 0.5);
    }
  } catch (e) {
    console.error('Failed to load settings:', e);
  }
}

async function loadFriends() {
  await sharingStore.getFriends();
  appState.setFriends(buildFriendsList());
}

// ─── Friends List Builder ────────────────────────────────────────────

/**
 * Build the friends list with model filter, period, and self-detection applied.
 * Port of MainWindowView.buildFriends() from Swift.
 */
function buildFriendsList() {
  const period = appState.pinnedDisplay;
  const modelFilter = appState.modelFilter;

  return sharingStore.friends.map(friend => {
    let currentTokens;
    if (friend.shareCode === sharingStore.shareCode) {
      // Use local data for self
      currentTokens = tokenStore.getForPeriod(period);
    } else {
      currentTokens = friend.tokens(modelFilter, period);
    }
    return {
      displayName: friend.displayName.slice(0, 7),
      formattedTokens: formatTokens(currentTokens),
      currentTokens,
      lastTokenChange: friend.lastTokenChange,
      shareCode: friend.shareCode,
    };
  });
}

// ─── Display Updates ─────────────────────────────────────────────────

function updateDisplay() {
  if (!splitFlapDisplay) return;

  // Row 1: pinned label + subtitles (model name left, "resets in Xh Ym" right)
  const modelName = getModelDisplayName();
  const resetTime = `resets in ${timeUntilReset()}`;
  splitFlapDisplay.setPinnedLabel(appState.pinnedLabel, modelName, resetTime);

  // Row 2: pinned value (split-flap)
  splitFlapDisplay.setPinnedValue(appState.pinnedValue);

  // Row 3: context label + subtitle
  splitFlapDisplay.setContextLabel(
    appState.displayLabel,
    '',
    appState.displaySubtitle || ''
  );

  // Row 4: context value (split-flap)
  splitFlapDisplay.setContextValue(appState.displayValue);
}

function getModelDisplayName() {
  const filter = appState.modelFilter;
  if (!filter) return 'All Models';
  if (filter === 'opus') return 'Opus';
  if (filter === 'sonnet') return 'Sonnet';
  if (filter === 'haiku') return 'Haiku';
  return filter.charAt(0).toUpperCase() + filter.slice(1);
}

// ─── Reset Countdown ─────────────────────────────────────────────────

function startResetCountdown() {
  if (resetCountdownTimer) clearInterval(resetCountdownTimer);
  resetCountdownTimer = setInterval(() => {
    updateDisplay(); // Subtitle refreshes with new timeUntilReset()
  }, 60000); // Every 60 seconds
}

// ─── Theme ───────────────────────────────────────────────────────────

// Normalize camelCase theme names to kebab-case for CSS data-theme attributes
const themeMap = { classicAmber: 'classic-amber', greenPhosphor: 'green-phosphor', whiteMinimal: 'white-minimal' };

function applyTheme(themeName) {
  const normalized = themeMap[themeName] || themeName;
  if (splitFlapDisplay && splitFlapDisplay.setTheme) {
    splitFlapDisplay.setTheme(normalized);
  }
}

// ─── Animation Speed ─────────────────────────────────────────────────

function applyAnimationSpeed(speed) {
  if (splitFlapDisplay && splitFlapDisplay.setAnimationSpeed) {
    splitFlapDisplay.setAnimationSpeed(speed);
  }
}

// ─── Reduced Motion ──────────────────────────────────────────────────

function applyReducedMotion() {
  const prefersReduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (splitFlapDisplay && splitFlapDisplay.setReducedMotion) {
    splitFlapDisplay.setReducedMotion(prefersReduced);
  }
  // Listen for changes
  window.matchMedia('(prefers-reduced-motion: reduce)').addEventListener('change', (e) => {
    if (splitFlapDisplay && splitFlapDisplay.setReducedMotion) {
      splitFlapDisplay.setReducedMotion(e.matches);
    }
  });
}

// ─── Cleanup ─────────────────────────────────────────────────────────

export function destroyMainWindow() {
  appState.stopContextRotation();
  menuBarState.stop();
  if (resetCountdownTimer) {
    clearInterval(resetCountdownTimer);
    resetCountdownTimer = null;
  }
  initialized = false;
}

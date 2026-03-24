// Settings window logic — reads/writes settings via Tauri invoke,
// emits events to main window for live updates.

const { invoke } = window.__TAURI__.core;
const { emit } = window.__TAURI__.event;
import { formatCompactTokens, formatModelName } from '../lib/formatting.js';

// ─── State ───────────────────────────────────────────────────────────

let settings = {};
let sharingState = { isRegistered: false, friends: [], shareCode: '', displayName: '', lastError: null };

// ─── Init ────────────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', async () => {
  await loadSettings();
  setupTabs();
  setupGeneralTab();
  setupDataTab();
  setupSharingTab();
  setupSoundTab();
  setupDisplayTab();
});

async function loadSettings() {
  try {
    settings = await invoke('get_settings');
  } catch (e) {
    console.error('Failed to load settings:', e);
    settings = {};
  }
  applySettingsToUI();
}

function applySettingsToUI() {
  // Period picker
  setSegmentedValue('period-picker', settings.pinnedDisplay || 'today');

  // Model filter
  const modelSelect = document.getElementById('model-filter');
  modelSelect.value = settings.modelFilter || 'opus';
  if (!settings.modelFilter) modelSelect.value = '__all__';

  // Toggles
  setToggle('realtime-flip', settings.realtimeFlipDisplay !== false);
  setToggle('menu-bar-tokens', settings.menuBarTokens !== false);
  setToggle('launch-login', settings.launchAtLogin === true);
  setToggle('jsonl-scanning', settings.jsonlScanning !== false);
  setToggle('sound-enabled', settings.soundEnabled === true);
  setToggle('sharing-enabled', settings.sharingEnabled === true);

  // Sound
  document.getElementById('sound-volume').value = (settings.soundVolume || 0.5) * 100;
  document.getElementById('sound-controls').style.display = settings.soundEnabled ? 'block' : 'none';

  // Animation speed
  const speed = settings.animationSpeed || 1.0;
  document.getElementById('animation-speed').value = speed;
  document.getElementById('speed-display').textContent = speed.toFixed(1) + 'x';

  // Theme — normalize camelCase to kebab-case for CSS compatibility
  const themeMap = { classicAmber: 'classic-amber', greenPhosphor: 'green-phosphor', whiteMinimal: 'white-minimal' };
  const theme = themeMap[settings.theme] || settings.theme || 'classic-amber';
  const radio = document.querySelector(`input[name="theme"][value="${theme}"]`);
  if (radio) radio.checked = true;

  // Sharing state
  loadSharingState();

  // Model breakdown
  loadModelBreakdown();
}

// ─── Tabs ────────────────────────────────────────────────────────────

function setupTabs() {
  const buttons = document.querySelectorAll('.tab-bar button');
  buttons.forEach(btn => {
    btn.addEventListener('click', () => {
      buttons.forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      document.querySelectorAll('.tab-content').forEach(tc => tc.classList.remove('active'));
      document.getElementById('tab-' + btn.dataset.tab).classList.add('active');
    });
  });
}

// ─── General Tab ─────────────────────────────────────────────────────

function setupGeneralTab() {
  // Period picker
  document.querySelectorAll('#period-picker button').forEach(btn => {
    btn.addEventListener('click', () => {
      setSegmentedValue('period-picker', btn.dataset.value);
      saveSetting('pinnedDisplay', btn.dataset.value);
      emitDisplayChange({ pinnedDisplay: btn.dataset.value });
    });
  });

  // Model filter
  document.getElementById('model-filter').addEventListener('change', (e) => {
    const value = e.target.value === '__all__' ? null : e.target.value;
    saveSetting('modelFilter', value);
    emitDisplayChange({ modelFilter: value });
  });

  // Toggles
  onToggle('realtime-flip', (checked) => {
    saveSetting('realtimeFlipDisplay', checked);
    emitDisplayChange({ realtimeFlipDisplay: checked });
  });

  onToggle('menu-bar-tokens', (checked) => {
    saveSetting('menuBarTokens', checked);
  });

  onToggle('launch-login', async (checked) => {
    try {
      await invoke('set_autostart', { enabled: checked });
    } catch (e) {
      console.error('Failed to set autostart:', e);
    }
  });
}

async function loadModelBreakdown() {
  try {
    const data = await invoke('get_token_data');
    const breakdown = data.todayByModel || [];
    const container = document.getElementById('model-breakdown');

    if (breakdown.length === 0) {
      container.innerHTML = '<div class="empty-state">No token data yet</div>';
      return;
    }

    container.innerHTML = breakdown.map(entry => `
      <div class="breakdown-item">
        <div class="breakdown-model">${escapeHtml(formatModelName(entry.model))}</div>
        <div class="breakdown-stats">
          <div>
            <div class="breakdown-stat-label">Output</div>
            <div class="breakdown-stat-value">${formatCompactTokens(entry.outputTokens || 0)}</div>
          </div>
          <div>
            <div class="breakdown-stat-label">Input (uncached)</div>
            <div class="breakdown-stat-value">${formatCompactTokens(entry.inputTokens || 0)}</div>
          </div>
          <div>
            <div class="breakdown-stat-label">Cache Read</div>
            <div class="breakdown-stat-value">${formatCompactTokens(entry.cacheRead || 0)}</div>
          </div>
          <div>
            <div class="breakdown-stat-label">Cache Write</div>
            <div class="breakdown-stat-value">${formatCompactTokens(entry.cacheCreate || 0)}</div>
          </div>
        </div>
      </div>
    `).join('');
  } catch (e) {
    console.error('Failed to load model breakdown:', e);
  }
}

// ─── Data Sources Tab ────────────────────────────────────────────────

function setupDataTab() {
  onToggle('jsonl-scanning', (checked) => {
    saveSetting('jsonlScanning', checked);
  });

  document.getElementById('rescan-btn').addEventListener('click', async () => {
    const btn = document.getElementById('rescan-btn');
    btn.disabled = true;
    btn.textContent = 'Scanning...';
    try {
      await invoke('rescan_jsonl');
    } catch (e) {
      console.error('Rescan failed:', e);
    }
    btn.disabled = false;
    btn.textContent = 'Rescan Now';
    loadModelBreakdown();
  });

  // Load DB info
  loadDbInfo();
}

async function loadDbInfo() {
  try {
    const s = await invoke('get_settings');
    document.getElementById('db-path').textContent = s.dbPath || 'Default location';
    document.getElementById('event-count').textContent = `Events: ${s.eventCount || '—'}`;
  } catch (e) {
    // Non-critical
  }
}

// ─── Sharing Tab ─────────────────────────────────────────────────────

function setupSharingTab() {
  // Display name input enables register button
  const nameInput = document.getElementById('display-name');
  const registerBtn = document.getElementById('register-btn');
  nameInput.addEventListener('input', () => {
    if (nameInput.value.length > 7) nameInput.value = nameInput.value.slice(0, 7);
    const trimmed = nameInput.value.trim();
    const valid = /^[A-Za-z0-9 ]*$/.test(trimmed);
    const nameError = document.getElementById('display-name-error');
    if (nameError) {
      nameError.textContent = !valid ? 'Only letters, numbers, and spaces allowed' : '';
      nameError.style.display = !valid ? 'block' : 'none';
    }
    registerBtn.disabled = trimmed.length === 0 || !valid;
  });

  // Register
  registerBtn.addEventListener('click', async () => {
    registerBtn.disabled = true;
    registerBtn.textContent = 'Registering...';
    try {
      const result = await invoke('register_sharing', { displayName: nameInput.value.trim() });
      sharingState.isRegistered = true;
      sharingState.shareCode = result.shareCode || '';
      sharingState.displayName = nameInput.value.trim().toUpperCase();
      saveSetting('shareCode', result.shareCode || '');
      saveSetting('secretToken', result.secretToken || '');
      saveSetting('displayName', sharingState.displayName);
      saveSetting('sharingEnabled', true);
      // Trigger immediate push
      try { await invoke('push_tokens', {}); } catch (_) {}
      loadSharingState();
    } catch (e) {
      sharingState.lastError = e.toString();
      showSharingError(e.toString());
    }
    registerBtn.disabled = false;
    registerBtn.textContent = 'Start Sharing';
  });

  // Sharing toggle
  onToggle('sharing-enabled', async (checked) => {
    saveSetting('sharingEnabled', checked);
    if (checked) {
      try { await invoke('push_tokens', {}); } catch (_) {}
    }
  });

  // Add friend
  const friendInput = document.getElementById('friend-input');
  const addBtn = document.getElementById('add-friend-btn');
  friendInput.addEventListener('input', () => {
    addBtn.disabled = friendInput.value.trim().length === 0;
  });

  addBtn.addEventListener('click', async () => {
    const errorEl = document.getElementById('add-friend-error');
    errorEl.style.display = 'none';
    addBtn.disabled = true;
    try {
      await invoke('add_friend', { input: friendInput.value.trim() });
      friendInput.value = '';
      await loadFriendsList();
    } catch (e) {
      errorEl.textContent = e.toString();
      errorEl.style.display = 'block';
    }
    addBtn.disabled = friendInput.value.trim().length === 0;
  });

  // Edit display name
  document.getElementById('edit-name-btn').addEventListener('click', () => {
    document.getElementById('edit-name-input').value = sharingState.displayName || '';
    document.getElementById('display-name-row').style.display = 'none';
    document.getElementById('edit-name-row').style.display = '';
    document.getElementById('edit-name-error').style.display = 'none';
    document.getElementById('edit-name-input').focus();
  });

  document.getElementById('cancel-name-btn').addEventListener('click', () => {
    document.getElementById('display-name-row').style.display = '';
    document.getElementById('edit-name-row').style.display = 'none';
  });

  document.getElementById('save-name-btn').addEventListener('click', async () => {
    const input = document.getElementById('edit-name-input');
    const errorEl = document.getElementById('edit-name-error');
    const name = input.value.trim();

    // Client-side validation
    if (name.length === 0 || name.length > 7) {
      errorEl.textContent = 'Display name must be 1-7 characters';
      errorEl.style.display = 'block';
      return;
    }
    if (!/^[A-Za-z0-9 ]+$/.test(name)) {
      errorEl.textContent = 'Only letters, numbers, and spaces allowed';
      errorEl.style.display = 'block';
      return;
    }

    errorEl.style.display = 'none';
    const saveBtn = document.getElementById('save-name-btn');
    saveBtn.disabled = true;
    try {
      await invoke('update_display_name', { displayName: name });
      const uppered = name.toUpperCase();
      sharingState.displayName = uppered;
      saveSetting('displayName', uppered);
      const dnEl = document.getElementById('current-display-name');
      dnEl.textContent = uppered;
      dnEl.style.fontStyle = '';
      dnEl.style.fontWeight = 'bold';
      document.getElementById('edit-name-btn').textContent = 'Edit';
      document.getElementById('display-name-row').style.display = '';
      document.getElementById('edit-name-row').style.display = 'none';
    } catch (e) {
      errorEl.textContent = e.toString();
      errorEl.style.display = 'block';
    }
    saveBtn.disabled = false;
  });

  // Reset & re-register
  document.getElementById('reset-btn').addEventListener('click', async () => {
    try {
      await invoke('reset_registration');
      sharingState.isRegistered = false;
      sharingState.shareCode = '';
      sharingState.lastError = null;
      loadSharingState();
    } catch (e) {
      showSharingError(e.toString());
    }
  });
}

async function loadSharingState() {
  try {
    const s = await invoke('get_settings');
    sharingState.isRegistered = !!s.shareCode;
    sharingState.shareCode = s.shareCode || '';
    sharingState.displayName = s.displayName || '';
    sharingState.sharingEnabled = s.sharingEnabled === true;
  } catch (_) {}

  const registerSection = document.getElementById('sharing-register');
  const registeredSection = document.getElementById('sharing-registered');
  const friendsSection = document.getElementById('sharing-friends');
  const errorSection = document.getElementById('sharing-error');

  if (sharingState.isRegistered) {
    registerSection.style.display = 'none';
    registeredSection.style.display = 'block';
    friendsSection.style.display = 'block';
    document.getElementById('share-code-display').textContent = sharingState.shareCode;
    const dnEl = document.getElementById('current-display-name');
    const editBtn = document.getElementById('edit-name-btn');
    if (sharingState.displayName) {
      dnEl.textContent = sharingState.displayName;
      editBtn.textContent = 'Edit';
    } else {
      dnEl.textContent = 'Not set';
      dnEl.style.fontStyle = 'italic';
      dnEl.style.fontWeight = 'normal';
      editBtn.textContent = 'Set Name';
    }
    setToggle('sharing-enabled', sharingState.sharingEnabled);
    // Reset edit row visibility
    document.getElementById('display-name-row').style.display = '';
    document.getElementById('edit-name-row').style.display = 'none';
    await loadFriendsList();
  } else {
    registerSection.style.display = 'block';
    registeredSection.style.display = 'none';
    friendsSection.style.display = 'none';
  }

  if (sharingState.lastError) {
    showSharingError(sharingState.lastError);
  } else {
    errorSection.style.display = 'none';
  }
}

async function loadFriendsList() {
  try {
    const friends = await invoke('get_friends');
    const container = document.getElementById('friends-list');

    if (!friends || friends.length === 0) {
      container.innerHTML = '<div class="empty-state">No friends added yet</div>';
      return;
    }

    container.innerHTML = friends.map(f => {
      const lastActive = f.lastTokenChange
        ? formatRelativeTime(f.lastTokenChange)
        : '';
      return `
        <div class="friend-item" data-code="${escapeHtml(f.shareCode)}">
          <div class="friend-info">
            <div class="friend-name">${escapeHtml(f.displayName)}</div>
            <div class="friend-code">${escapeHtml(f.shareCode)}</div>
            ${lastActive ? `<div class="friend-active">Last active ${escapeHtml(lastActive)}</div>` : ''}
          </div>
          <button class="friend-remove" data-code="${escapeHtml(f.shareCode)}">Remove</button>
        </div>
      `;
    }).join('');

    // Wire remove buttons
    container.querySelectorAll('.friend-remove').forEach(btn => {
      btn.addEventListener('click', async () => {
        try {
          await invoke('remove_friend', { code: btn.dataset.code });
          await loadFriendsList();
          emit('friends-changed', {});
        } catch (e) {
          console.error('Remove friend failed:', e);
        }
      });
    });
  } catch (e) {
    console.error('Failed to load friends:', e);
  }
}

function showSharingError(msg) {
  const section = document.getElementById('sharing-error');
  document.getElementById('sharing-error-text').textContent = msg;
  section.style.display = 'block';
  // Show reset button only for token-related errors
  document.getElementById('reset-btn').style.display =
    (msg.includes('re-register') || msg.includes('token')) ? 'inline-block' : 'none';
}

function formatRelativeTime(iso) {
  if (!iso) return '';
  const date = new Date(iso);
  if (isNaN(date.getTime())) return iso;
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

// ─── Sound Tab ───────────────────────────────────────────────────────

function setupSoundTab() {
  onToggle('sound-enabled', (checked) => {
    saveSetting('soundEnabled', checked);
    document.getElementById('sound-controls').style.display = checked ? 'block' : 'none';
    emit('display-settings-changed', { soundEnabled: checked });
  });

  document.getElementById('sound-volume').addEventListener('input', (e) => {
    const volume = parseInt(e.target.value, 10) / 100;
    saveSetting('soundVolume', volume);
    emit('display-settings-changed', { soundVolume: volume });
  });

  document.getElementById('preview-sound-btn').addEventListener('click', () => {
    emit('preview-sound', {});
  });
}

// ─── Display Tab ─────────────────────────────────────────────────────

function setupDisplayTab() {
  // Animation speed
  const speedSlider = document.getElementById('animation-speed');
  const speedDisplay = document.getElementById('speed-display');
  speedSlider.addEventListener('input', () => {
    const val = parseFloat(speedSlider.value);
    speedDisplay.textContent = val.toFixed(1) + 'x';
    saveSetting('animationSpeed', val);
    emitDisplayChange({ animationSpeed: val });
  });

  // Theme picker
  document.querySelectorAll('.theme-option').forEach(opt => {
    opt.addEventListener('click', () => {
      const radio = opt.querySelector('input[type="radio"]');
      radio.checked = true;
      saveSetting('theme', radio.value);
      emitDisplayChange({ theme: radio.value });
    });
  });
}

// ─── Helpers ─────────────────────────────────────────────────────────

async function saveSetting(key, value) {
  try {
    await invoke('save_setting', { key, value });
  } catch (e) {
    console.error(`Failed to save setting ${key}:`, e);
  }
}

function emitDisplayChange(payload) {
  emit('display-settings-changed', payload);
}

function setSegmentedValue(id, value) {
  const container = document.getElementById(id);
  container.querySelectorAll('button').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.value === value);
  });
}

function setToggle(id, checked) {
  document.getElementById(id).checked = checked;
}

function onToggle(id, callback) {
  document.getElementById(id).addEventListener('change', (e) => {
    callback(e.target.checked);
  });
}

function escapeHtml(str) {
  const div = document.createElement('div');
  div.textContent = str;
  return div.innerHTML;
}

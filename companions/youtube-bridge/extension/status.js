/* global chrome */

const statusKeys = ['nativeConnection', 'nativeStatus', 'lastYouTubeState'];

const rows = {
  extension: {
    row: document.getElementById('row-extension'),
    value: document.getElementById('extension-status'),
  },
  nativeConnection: {
    row: document.getElementById('row-native-connection'),
    value: document.getElementById('native-connection'),
  },
  mediaKeyTap: {
    row: document.getElementById('row-media-key-tap'),
    value: document.getElementById('media-key-tap'),
  },
  accessibility: {
    row: document.getElementById('row-accessibility'),
    value: document.getElementById('accessibility'),
  },
  spotifyState: {
    row: document.getElementById('row-spotify-state'),
    value: document.getElementById('spotify-state'),
  },
  youtubeTab: {
    row: document.getElementById('row-youtube-tab'),
    value: document.getElementById('youtube-tab'),
  },
  lastOwner: {
    row: document.getElementById('row-last-owner'),
    value: document.getElementById('last-owner'),
  },
  nativeStatus: {
    row: document.getElementById('row-native-status'),
    value: document.getElementById('native-status'),
  },
};

const summary = document.getElementById('summary');
const refreshButton = document.getElementById('refresh');
const lastRefresh = document.getElementById('last-refresh');

let isRefreshing = false;
let lastRenderedStatus = {};

/**
 * @param {unknown} value
 * @returns {value is Record<string, unknown>}
 */
const isRecord = (value) =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

/**
 * @param {unknown} value
 * @returns {Record<string, unknown>}
 */
const record = (value) => (isRecord(value) ? value : {});

/**
 * @param {unknown} value
 * @param {string} fallback
 * @returns {string}
 */
const text = (value, fallback) => {
  if (value === undefined || value === null || value === '') {
    return fallback;
  }

  return String(value);
};

/**
 * @param {unknown} timestamp
 * @returns {string}
 */
const age = (timestamp) => {
  if (typeof timestamp !== 'number') {
    return '';
  }

  const seconds = Math.max(0, Math.round((Date.now() - timestamp) / 1000));

  if (seconds < 60) {
    return `${seconds}s ago`;
  }

  return `${Math.round(seconds / 60)}m ago`;
};

/**
 * @param {keyof rows} key
 * @param {'ok' | 'warn' | 'error' | 'neutral'} state
 * @param {string} value
 */
const setRow = (key, state, value) => {
  const row = rows[key].row;
  const field = rows[key].value;

  row?.classList.remove('is-ok', 'is-warn', 'is-error', 'is-neutral');
  row?.classList.add(`is-${state}`);

  if (field) {
    field.textContent = value;
    field.title = value;
  }
};

/**
 * @param {'ok' | 'warn' | 'error' | 'neutral'} state
 * @param {string} value
 */
const setSummary = (state, value) => {
  summary?.classList.remove('is-ok', 'is-warn', 'is-error', 'is-neutral');
  summary?.classList.add(`is-${state}`);

  if (summary) {
    summary.textContent = value;
    summary.title = value;
  }
};

/**
 * @returns {Promise<Record<string, unknown>>}
 */
const getCachedStatus = () =>
  new Promise((resolve) => {
    try {
      if (!chrome.storage?.local) {
        resolve({});
        return;
      }

      chrome.storage.local.get(statusKeys, (cachedStatus) => {
        resolve(record(cachedStatus));
      });
    } catch {
      resolve({});
    }
  });

/**
 * @param {boolean} refreshYouTube
 * @returns {Promise<{ response: Record<string, unknown>; error: string }>}
 */
const requestBackgroundStatus = (refreshYouTube) =>
  new Promise((resolve) => {
    try {
      if (!chrome.runtime?.sendMessage) {
        resolve({
          response: {},
          error: 'Extension runtime is unavailable.',
        });
        return;
      }

      chrome.runtime.sendMessage(
        { type: 'status-request', refreshYouTube, popupTimestamp: Date.now() },
        (response) => {
          const error = chrome.runtime.lastError?.message ?? '';
          resolve({
            response: record(response),
            error,
          });
        },
      );
    } catch (error) {
      resolve({
        response: {},
        error: String(error),
      });
    }
  });

/**
 * @param {Record<string, unknown>} cachedStatus
 * @param {Record<string, unknown>} backgroundStatus
 * @param {string} requestError
 * @returns {Record<string, unknown>}
 */
const mergeStatus = (cachedStatus, backgroundStatus, requestError) => ({
  extensionStatus: backgroundStatus.extensionStatus,
  nativeConnection:
    backgroundStatus.nativeConnection ?? cachedStatus.nativeConnection,
  nativeStatus: backgroundStatus.nativeStatus ?? cachedStatus.nativeStatus,
  lastYouTubeState:
    backgroundStatus.lastYouTubeState ?? cachedStatus.lastYouTubeState,
  backgroundTimestamp: backgroundStatus.backgroundTimestamp,
  requestError,
  renderedAt: Date.now(),
});

/**
 * @param {Record<string, unknown>} status
 */
const render = (status) => {
  const nativeConnection = record(status.nativeConnection);
  const nativeStatus = record(status.nativeStatus);
  const lastYouTubeState = record(status.lastYouTubeState);
  const requestError = text(status.requestError, '');
  const backgroundAge = age(status.backgroundTimestamp);
  const nativeStatusAge = age(nativeStatus.nativeTimestamp);
  const hardwareMediaKeyRoutingDisabled = text(nativeStatus.mediaKeyTapError, '')
    .startsWith('Hardware media-key routing is disabled');
  const nativeMessage = text(nativeStatus.message, '');
  const voiceInkPausePending = nativeStatus.voiceInkPausePending === true;
  const voiceInkResumePending =
    typeof nativeStatus.voiceInkResumePendingTabId === 'number';
  const youtubePausedForDictation =
    typeof nativeStatus.youtubePausedForDictationTabId === 'number';
  const youtubeAge = age(
    lastYouTubeState.contentTimestamp ?? lastYouTubeState.extensionTimestamp,
  );

  if (requestError) {
    setSummary('warn', 'Background issue');
    setRow('extension', 'warn', `Background: ${requestError}`);
  } else {
    setRow(
      'extension',
      'ok',
      backgroundAge ? `Background loaded, ${backgroundAge}` : 'Background loaded',
    );
  }

  if (nativeConnection.connected === true) {
    setRow(
      'nativeConnection',
      'ok',
      `Connected${age(nativeConnection.extensionTimestamp) ? `, ${age(nativeConnection.extensionTimestamp)}` : ''}`,
    );
  } else {
    const message = text(nativeConnection.message, 'not-connected');
    const state = message === 'connect-failed' ? 'error' : 'warn';
    setRow('nativeConnection', state, text(message, 'Not connected yet'));
  }

  if (nativeStatus.mediaKeyTapInstalled === true) {
    setRow('mediaKeyTap', 'ok', 'Installed');
  } else if (hardwareMediaKeyRoutingDisabled) {
    setRow('mediaKeyTap', 'ok', 'Disabled by design');
  } else if (nativeStatus.mediaKeyTapInstalled === false) {
    setRow(
      'mediaKeyTap',
      'error',
      text(nativeStatus.mediaKeyTapError, 'Unavailable'),
    );
  } else {
    setRow('mediaKeyTap', 'neutral', 'No host status yet');
  }

  if (nativeStatus.accessibilityTrusted === true) {
    setRow('accessibility', 'ok', 'Trusted');
  } else if (hardwareMediaKeyRoutingDisabled) {
    setRow('accessibility', 'neutral', 'Not needed');
  } else if (nativeStatus.accessibilityTrusted === false) {
    setRow('accessibility', 'error', 'App switch is off');
  } else {
    setRow('accessibility', 'neutral', 'No host status yet');
  }

  switch (nativeStatus.spotifyState) {
    case 'playing':
      setRow('spotifyState', 'ok', 'Playing');
      break;
    case 'paused':
      setRow('spotifyState', 'neutral', 'Paused');
      break;
    case 'stopped':
      setRow('spotifyState', 'neutral', 'Stopped');
      break;
    case 'notRunning':
      setRow('spotifyState', 'warn', 'Not running');
      break;
    case 'unknown':
      setRow('spotifyState', 'neutral', 'Unknown');
      break;
    case undefined:
      setRow('spotifyState', 'neutral', 'No host status yet');
      break;
    default:
      setRow('spotifyState', 'neutral', text(nativeStatus.spotifyState, 'Unknown'));
      break;
  }

  const youtubeTabId = nativeStatus.youtubeTabId ?? lastYouTubeState.tabId;

  if (typeof youtubeTabId === 'number') {
    const playback = lastYouTubeState.playing === true ? 'playing' : 'paused';
    let label = youtubeAge
      ? `Tab ${youtubeTabId}, ${playback}, ${youtubeAge}`
      : `Tab ${youtubeTabId}, ${playback}`;

    if (voiceInkPausePending) {
      label = `${label}, pause pending`;
    } else if (voiceInkResumePending) {
      label = `${label}, resume pending`;
    } else if (youtubePausedForDictation) {
      label = `${label}, paused for VoiceInk`;
    }

    setRow(
      'youtubeTab',
      lastYouTubeState.playing === true ? 'ok' : 'neutral',
      label,
    );
  } else {
    setRow('youtubeTab', 'neutral', 'No YouTube tab reported');
  }

  switch (nativeStatus.lastMediaOwner) {
    case 'youtube':
      setRow('lastOwner', 'ok', 'YouTube');
      break;
    case 'spotify':
      setRow('lastOwner', 'neutral', 'Spotify');
      break;
    case undefined:
    case null:
      setRow('lastOwner', 'neutral', 'None yet');
      break;
    default:
      setRow('lastOwner', 'neutral', text(nativeStatus.lastMediaOwner, 'None yet'));
      break;
  }

  if (nativeMessage) {
    setRow(
      'nativeStatus',
      nativeMessage.endsWith('-timeout') ? 'error' : 'neutral',
      nativeStatusAge
        ? `${nativeMessage}, ${nativeStatusAge}`
        : nativeMessage,
    );
  } else {
    setRow('nativeStatus', 'neutral', 'No host message yet');
  }

  if (requestError) {
    setSummary('warn', 'Background issue');
  } else if (voiceInkPausePending) {
    setSummary('warn', 'Pausing YouTube');
  } else if (voiceInkResumePending) {
    setSummary('warn', 'Resuming YouTube');
  } else if (nativeMessage === 'voiceink-pause-youtube-timeout') {
    setSummary('error', 'Reload YouTube');
  } else if (nativeMessage === 'voiceink-resume-youtube-timeout') {
    setSummary('error', 'Resume failed');
  } else if (
    nativeConnection.connected === true &&
    (nativeStatus.mediaKeyTapInstalled === true || hardwareMediaKeyRoutingDisabled)
  ) {
    setSummary('ok', 'Ready');
  } else if (nativeConnection.connected === true) {
    setSummary('warn', 'Host partial');
  } else {
    setSummary('warn', 'Host offline');
  }

  if (lastRefresh) {
    lastRefresh.textContent = `Updated ${age(status.renderedAt) || 'now'}`;
  }
};

/**
 * @param {boolean} requestFreshStatus
 */
const refresh = async (requestFreshStatus) => {
  if (requestFreshStatus && isRefreshing) {
    return;
  }

  isRefreshing = requestFreshStatus;
  refreshButton?.toggleAttribute('disabled', requestFreshStatus);

  const cachedStatus = await getCachedStatus();
  const backgroundResult = await requestBackgroundStatus(requestFreshStatus);

  lastRenderedStatus = mergeStatus(
    cachedStatus,
    backgroundResult.response,
    backgroundResult.error,
  );

  render(lastRenderedStatus);

  isRefreshing = false;
  refreshButton?.toggleAttribute('disabled', false);
};

refreshButton?.addEventListener('click', () => {
  window.location.reload(); // The status page can show stale service-worker state after extension reloads; make the button do the same full reload the user expects.
});

void refresh(true);
window.setInterval(() => {
  void refresh(false);
}, 1000);

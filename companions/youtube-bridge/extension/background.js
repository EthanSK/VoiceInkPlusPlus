/* global chrome, createChromeTabHistoryController, createChromeWebsiteOpener */

importScripts('tab-history.js', 'website-opener.js');

const nativeHostName = 'com.ethan.youtube_spotify_media_key';
const youtubeUrlPatterns = ['*://youtube.com/*', '*://*.youtube.com/*'];

/** @type {chrome.runtime.Port | null} */
let nativePort = null;

/** @type {number | undefined} */
let nativeReconnectTimeout;

/** @type {Array<() => void>} */
let pendingNativeStatusResolvers = [];

const statusState = {
  extensionStatus: {
    loaded: true,
    extensionTimestamp: Date.now(),
  },
  nativeConnection: {
    connected: false,
    message: 'not-connected',
    extensionTimestamp: Date.now(),
  },
  nativeStatus: null,
  lastYouTubeState: null,
};

const chromeTabHistory = createChromeTabHistoryController({
  log: (message) => clog('background', message),
});
const chromeWebsiteOpener = createChromeWebsiteOpener({
  log: (message) => clog('background', message),
});

// -- Most-recently-played tracking: the EXTENSION owns "which video to pause" --------------------
//
// WHY this lives here now (the rearchitecture): only the extension sees every YouTube tab's
// real-time <video> play/pause state. The menu-bar app used to try to track tab ids and pick the
// target, which got confused when Ethan runs ~5 YouTube tabs (2nd dictation paused the wrong tab or
// nothing). So the decision "which tab to pause for this dictation" moved IN HERE: we keep a
// per-tab "most recently played" timestamp and, on each pause command, pick the tab the user is
// actually watching (PiP first, then the active tab in Chrome's last-focused window, then audible /
// active fallbacks). Playback recency only breaks ties after those live attention signals.
//
// State shape:
//   tabPlayState: tabId -> { lastPlayedAt, playing, title, url }
//     lastPlayedAt = the latest wall-clock ms at which this tab STARTED playing. Heartbeats must NOT
//     advance it: with several playing tabs their 5s heartbeat order is arbitrary, and treating each
//     heartbeat as fresh playback made a hidden tab randomly outrank the active video. When the tab
//     pauses we FREEZE it so the "played very recently" fallback can still find it.
//   dictationPausedTabId = the single tab we paused for the in-progress dictation. On resume we
//     resume EXACTLY this tab, then clear it ("resume exactly what we paused" invariant).
//
// MV3 caveat: this is a service worker; Chrome can SLEEP it between the pause (VoiceInk record
// start) and the resume (record stop), wiping these in-memory values. So we mirror BOTH to
// chrome.storage.local and rehydrate on demand (hydrateFromStorage) before handling any command.

// A tab that isn't "currently playing" but played within this window is still a valid fallback
// target — its playing flag may just be stale (worker missed the event) and the content script
// re-checks live before actually pausing, so sending it a pause is a safe no-op if it truly isn't.
const RECENT_PLAY_FALLBACK_MS = 60000;
const TAB_PLAY_STATE_STORAGE_KEY = 'tabPlayState';
const DICTATION_PAUSED_TAB_STORAGE_KEY = 'dictationPausedTabId';
const AGENTIC_MOUSE_SPEED_HOLD_STORAGE_KEY = 'agenticMouseYouTubeSpeedHold';

// -- Manual-pause ADOPT feature -------------------------------------------------------------------
//
// PROBLEM: Ethan sometimes ACCIDENTALLY pauses the YouTube video himself (spacebar / click) right as
// he starts a VoiceInk dictation. Because HE paused it (not our `pause-youtube` command), the normal
// path finds the video already paused → remembers NO dictation target → the dictation-stop resume
// does nothing → the video stays paused and he has to hit play manually.
//
// FIX: if a MANUAL pause lands just BEFORE the dictation starts, ADOPT it as the old accidental
// spacebar race. A manual Play/Pause at or after the start is explicit user control and instead
// relinquishes the bridge's target so stop cannot override it.
//
// Gated to ~1s because only the just-before race is eligible; post-start actions are never adopted.
const MANUAL_PAUSE_ADOPT_WINDOW_MS = 1000;
// Manual-pause records older than this are pruned: bounds the map and stops a stale pause from a
// PREVIOUS dictation ever being adopted (a 2-min-old manual pause can't be within 1s of a new start,
// but pruning is belt-and-braces + keeps the persisted blob small).
const RECENT_MANUAL_PAUSE_PRUNE_MS = 10000;
const DICTATION_STATE_STORAGE_KEY = 'dictationState';
const RECENT_MANUAL_PAUSES_STORAGE_KEY = 'recentManualPauses';

// -- Robust dictation lifecycle (2026-07-09 flake fix) --------------------------------------------
//
// THE FLAKE (root causes, evidence-backed from the live log + Codex): the previous design tracked a
// single boolean `dictationActive` + one `dictationStartedAt` + one `dictationPausedTabId`, mutated
// by pause/resume commands that were fired WITHOUT awaiting (`void pauseYouTubeForDictation(...)`),
// so they could interleave and corrupt each other. Worse, there was NO expiry: if a
// `recordingStopped` was ever dropped (DistributedNotificationCenter is lossy) or two dictations
// overlapped, `dictationActive`/`dictationStartedAt`/`dictationPausedTabId` got stuck — the live log
// showed dictationActive=true with a startedAt 3+ MINUTES old, which then (a) broke the manual-pause
// adopt window (measured against that ancient start), and (b) left a STALE paused-tab target so the
// next resume played the WRONG tab and the actually-paused tab stayed stuck = the "resume is flaky"
// symptom Ethan reported. Overlapping dictations (2nd starts while 1st transcribes) also resumed
// early or left the video stuck because there was no ref-counting.
//
// THE FIX (this block + enqueueDictationOp + the watchdog):
//   1. SERIALIZE every pause/resume/adopt through `dictationOpChain` so they can never interleave.
//   2. REF-COUNT with `dictationDepth`: recordingStarted increments, recordingStopped decrements, and
//      we only actually RESUME when depth returns to 0. This makes overlapping dictations correct —
//      the video stays paused across all of them and resumes once at the very end.
//   3. SELF-HEAL stale state: `dictationLastActivityAt` + MAX_DICTATION_MS. If a new dictation starts
//      while the previous session looks abandoned (no activity for too long ⇒ a dropped stop), we
//      reset before starting fresh; the chrome.alarms watchdog also clears stale ownership without
//      changing playback. A timeout is not user intent and must never call play().
//   4. A `dictationSessionToken` bumped on every reset lets async retries detect they belong to an
//      old, superseded session and abort.
const MAX_DICTATION_MS = 4 * 60 * 1000; // A single dictation lasting >4min ⇒ almost certainly a dropped stop.
const DICTATION_WATCHDOG_ALARM = 'dictation-watchdog';
const DICTATION_WATCHDOG_PERIOD_MINUTES = 1; // chrome.alarms min period; checks staleness each tick.

// -- Keep-warm alarm (FIX 3, 2026-07-09): the dominant backgrounded-Chrome failure --------------
//
// THE BUG: this is an MV3 service worker. Chrome idle-SUSPENDS it after ~30s of no events. The native
// messaging host process is a CHILD of the service worker, so when the worker dies the native host
// exits on stdin EOF. The menu-bar app reaches Chrome ONLY through that native host (app posts an
// appToBridge DistributedNotification → native host observes → relays into Chrome). So once the worker
// sleeps, the app's pause-youtube/resume-youtube has NO observer — the command is silently dropped and
// there is no wake path (a suspended MV3 worker cannot be woken by an incoming native message; the
// port/host don't survive suspension). The only prior keep-alive was the content script's 5s heartbeat,
// which is ITSELF throttled to >=1s→~1/min when the YT tab is backgrounded — i.e. it fails in exactly
// the situation that matters. Confirmed by multi-second `bridge-disconnected` dead windows in the log.
//
// THE FIX: an ALWAYS-ON alarm, independent of the dictation watchdog. chrome.alarms wake the service
// worker even from full suspension. Each fire is an SW event that resets the 30s idle timer, so the
// worker — and its child native host — stay alive even when every YT tab is backgrounded and the
// heartbeat is throttled. 0.5min is the unpacked-extension floor. On each tick we also ensure the
// native port is up (this is the durable reconnect path that survives worker termination, unlike the
// setTimeout in scheduleNativeReconnect). This removes the "SW suspended → native host dead → command
// dropped" window that caused pause/resume to never arrive when Chrome was backgrounded.
const KEEP_WARM_ALARM = 'keep-warm';
const KEEP_WARM_PERIOD_MINUTES = 0.5;

/** @type {Map<number, { lastPlayedAt: number, playing: boolean, title: string, url: string, isPiP: boolean }>} */
let tabPlayState = new Map();

// The single tab we paused for the CURRENT dictation session. On resume we play EXACTLY this tab then
// clear it ("resume exactly what we paused"). Persisted so an MV3 worker sleep between the pause
// (record-start) and the resume (record-stop) can't lose which video to restore.
/** @type {number | null} */
let dictationPausedTabId = null;

// Ref count of outstanding dictations: incremented on each recordingStarted (pause-youtube),
// decremented on each recordingStopped (resume-youtube). We resume only on the 1→0 edge. Persisted so
// a worker sleep mid-session survives. Floored at 0 so a stray/duplicate stop can't drive it negative.
let dictationDepth = 0;
// When the CURRENT session began (set on the 0→1 edge). Used for the manual-pause adopt window and to
// detect an implausibly long "stuck" session. Persisted.
/** @type {number | null} */
let dictationStartedAt = null;
// Wall-clock ms of the last recordingStarted/Stopped we processed. The watchdog + start-time self-heal
// use this to decide a session has been abandoned (dropped stop). Persisted.
let dictationLastActivityAt = 0;
// Bumped on every session reset. An async resume-retry captures the token it started under and aborts
// if the token has since changed (a new session began), so a slow retry can't fight the new session.
let dictationSessionToken = 0;
let dictationPlaybackRelinquished = false; // Only a genuine manual Play/Pause after recording starts sets this; stop then balances state without touching playback. Timeouts, reloads, and bridge-owned commands never set it. (Codex task: 01a039f7-873c-7c30-b3dc-af8a6724ace5)

// Derived convenience: is a dictation session currently in progress? (Replaces the old standalone
// `dictationActive` boolean — same meaning, single source of truth = the ref count.)
const isDictationActive = () => dictationDepth > 0;

/** @type {Map<number, number>} tabId -> wall-clock ms of the last MANUAL (user-initiated) pause. */
let recentManualPauses = new Map();

// -- Command serialization ------------------------------------------------------------------------
// Every dictation state mutation (pause / resume / manual-pause adopt) runs through this promise
// chain so two commands can NEVER interleave their hydrate→mutate→persist sequence. This is the core
// guard against the async-overlap corruption that caused the flake. Each op is queued and awaited in
// arrival order; a throwing op is swallowed so it can't wedge the chain.
/** @type {Promise<void>} */
let dictationOpChain = Promise.resolve();

// Keep physical begin/renew/end edges in arrival order. A quick tap can release
// while begin is still selecting/injecting its target; without serialization,
// the early end would see no stored target and begin could strand 2× until the
// page lease expired.
/** @type {Promise<void>} */
let agenticMouseSpeedHoldOpChain = Promise.resolve();

const enqueueAgenticMouseSpeedHoldOp = (label, op) => {
  agenticMouseSpeedHoldOpChain = agenticMouseSpeedHoldOpChain.then(async () => {
    try {
      await op();
    } catch (error) {
      clog('background', `youtube speed-hold op "${label}" threw: ${String(error)}`);
    }
  });
  return agenticMouseSpeedHoldOpChain;
};

// Number of pause commands that have arrived but whose serialized operation has not completed yet.
// A new start can arrive while the preceding stop is still awaiting resume confirmation. Keeping this
// arrival-time signal lets that resume abort before it plays the video underneath the new recording.
let pendingPauseCommandCount = 0;

/**
 * Enqueue a dictation operation to run strictly after all previously-enqueued ones complete.
 * @param {string} label  Diagnostic label for logs.
 * @param {() => Promise<void>} op
 * @returns {Promise<void>}
 */
const enqueueDictationOp = (label, op) => {
  dictationOpChain = dictationOpChain.then(async () => {
    try {
      await op();
    } catch (error) {
      // A failed op must never break the chain for the NEXT command (that would strand every future
      // pause/resume). Log and move on.
      clog('background', `dictation op "${label}" threw: ${String(error)}`);
    }
  });
  return dictationOpChain;
};

/**
 * Reset all per-session dictation state to a clean slate and bump the session token so any in-flight
 * async retry from the old session aborts. Called when a session completes normally (resume at
 * depth 0), when the watchdog force-heals a stranded session, and when a fresh start finds the prior
 * session abandoned. Does NOT touch tabPlayState (that's the long-lived most-recently-played tracker).
 * @param {string} why  Diagnostic reason.
 */
const resetDictationSession = (why) => {
  dictationDepth = 0;
  dictationStartedAt = null;
  dictationLastActivityAt = 0;
  dictationPausedTabId = null;
  dictationPlaybackRelinquished = false;
  dictationSessionToken += 1;
  recentManualPauses.clear();
  persistDictationPausedTabId();
  persistDictationState();
  persistRecentManualPauses();
  clog('background', `dictation session RESET (${why}) token=${dictationSessionToken}`);
};

const persistTabPlayState = () => {
  try {
    chrome.storage.local.set({
      [TAB_PLAY_STATE_STORAGE_KEY]: Object.fromEntries(tabPlayState),
    });
  } catch {
    // Storage is a durability aid across worker sleep; never let it break pause/resume control flow.
  }
};

const persistDictationPausedTabId = () => {
  try {
    chrome.storage.local.set({
      [DICTATION_PAUSED_TAB_STORAGE_KEY]: dictationPausedTabId,
    });
  } catch {
    // Same rationale as persistTabPlayState — best-effort durability only.
  }
};

const persistDictationState = () => {
  try {
    chrome.storage.local.set({
      [DICTATION_STATE_STORAGE_KEY]: {
        depth: dictationDepth,
        startedAt: dictationStartedAt,
        lastActivityAt: dictationLastActivityAt,
        // Persist the token too so a woken worker doesn't reuse an id an old retry still holds.
        token: dictationSessionToken,
        playbackRelinquished: dictationPlaybackRelinquished,
      },
    });
  } catch {
    // Best-effort durability across MV3 worker sleep; never break pause/resume control flow.
  }
};

const persistRecentManualPauses = () => {
  try {
    chrome.storage.local.set({
      [RECENT_MANUAL_PAUSES_STORAGE_KEY]: Object.fromEntries(recentManualPauses),
    });
  } catch {
    // Best-effort durability only.
  }
};

/**
 * Rehydrate the most-recently-played map + the remembered dictation-paused tab from
 * chrome.storage.local. Called before handling any pause/resume command because the MV3 service
 * worker may have slept (and wiped the in-memory Maps) since the last event. We MERGE rather than
 * clobber: an in-memory entry that is newer than the stored one (because a fresh report already woke
 * the worker) wins, so we never regress to stale persisted state.
 * @returns {Promise<void>}
 */
const hydrateFromStorage = async () => {
  try {
    const stored = await chrome.storage.local.get([
      TAB_PLAY_STATE_STORAGE_KEY,
      DICTATION_PAUSED_TAB_STORAGE_KEY,
      DICTATION_STATE_STORAGE_KEY,
      RECENT_MANUAL_PAUSES_STORAGE_KEY,
    ]);

    const storedMap = stored[TAB_PLAY_STATE_STORAGE_KEY];
    if (storedMap && typeof storedMap === 'object') {
      for (const [key, value] of Object.entries(storedMap)) {
        const tabId = Number(key);
        if (!Number.isInteger(tabId) || !value || typeof value !== 'object') {
          continue;
        }

        const storedLastPlayedAt =
          typeof value.lastPlayedAt === 'number' ? value.lastPlayedAt : 0;
        const existing = tabPlayState.get(tabId);

        if (!existing || storedLastPlayedAt > existing.lastPlayedAt) {
          tabPlayState.set(tabId, {
            lastPlayedAt: storedLastPlayedAt,
            playing: value.playing === true,
            title: typeof value.title === 'string' ? value.title : '',
            url: typeof value.url === 'string' ? value.url : '',
            isPiP: value.isPiP === true,
          });
        }
      }
    }

    if (
      dictationPausedTabId === null &&
      typeof stored[DICTATION_PAUSED_TAB_STORAGE_KEY] === 'number'
    ) {
      dictationPausedTabId = stored[DICTATION_PAUSED_TAB_STORAGE_KEY];
    }

    // Restore the dictation session (depth + timing + token) that a since-slept worker may have
    // started. We restore ONLY when the live worker currently believes NO dictation is active
    // (dictationDepth === 0) so this can never fight a command that's mid-way establishing state.
    // This is what lets the resume command, running on a freshly-woken worker, know a session is in
    // flight and which tab to restore.
    const storedDictationState = stored[DICTATION_STATE_STORAGE_KEY];
    if (
      dictationDepth === 0 &&
      storedDictationState &&
      typeof storedDictationState === 'object' &&
      typeof storedDictationState.depth === 'number' &&
      storedDictationState.depth > 0
    ) {
      dictationDepth = storedDictationState.depth;
      dictationStartedAt =
        typeof storedDictationState.startedAt === 'number' ? storedDictationState.startedAt : Date.now();
      dictationLastActivityAt =
        typeof storedDictationState.lastActivityAt === 'number'
          ? storedDictationState.lastActivityAt
          : dictationStartedAt;
      // Keep the token monotonic across the sleep so old async retries stay invalidated.
      if (typeof storedDictationState.token === 'number' && storedDictationState.token > dictationSessionToken) {
        dictationSessionToken = storedDictationState.token;
      }
      dictationPlaybackRelinquished = storedDictationState.playbackRelinquished === true;
    }

    // Merge the persisted manual-pause records (keeping the newest timestamp per tab) so a manual
    // pause reported to a worker that then slept still counts when the dictation-start command runs.
    const storedManualPauses = stored[RECENT_MANUAL_PAUSES_STORAGE_KEY];
    if (storedManualPauses && typeof storedManualPauses === 'object') {
      const cutoff = Date.now() - RECENT_MANUAL_PAUSE_PRUNE_MS;
      for (const [key, value] of Object.entries(storedManualPauses)) {
        const tabId = Number(key);
        if (!Number.isInteger(tabId) || typeof value !== 'number' || value < cutoff) {
          continue;
        }
        const existing = recentManualPauses.get(tabId);
        if (existing === undefined || value > existing) {
          recentManualPauses.set(tabId, value);
        }
      }
    }
  } catch {
    // If storage is unavailable we still have whatever the live content-script reports gave us.
  }
};

/**
 * Update the most-recently-played tracker from a content-script youtube-state report. Heartbeats
 * refresh the boolean state but deliberately do not refresh playback recency; otherwise several
 * concurrently-playing tabs rotate the "winner" based only on arbitrary heartbeat arrival order.
 * @param {number} tabId
 * @param {boolean} playing
 * @param {string} title
 * @param {string} url
 * @param {boolean} isPiP  Whether this tab currently has a video in Picture-in-Picture.
 * @param {string} reason  Content-script report reason (`play`, `heartbeat`, etc.).
 * @param {number | undefined} contentTimestamp  Page-clock timestamp for the originating event.
 */
const recordTabPlayState = (tabId, playing, title, url, isPiP, reason, contentTimestamp) => {
  const observedAt = typeof contentTimestamp === 'number' ? contentTimestamp : Date.now();
  const previous = tabPlayState.get(tabId);
  const isPlaybackStartReport = ['play', 'playing', 'native-toggle', 'voiceink-resume'].includes(reason);
  const didStartPlayback =
    playing &&
    (previous?.playing !== true || isPlaybackStartReport || (previous?.url && previous.url !== url));
  // Bug fix: a playing heartbeat preserves the original start time instead of becoming "most recent";
  // repro was five hidden playing tabs leapfrogging the watched tab every ~5s, so dictation paused one
  // of them while the active YouTube video kept playing.
  const lastPlayedAt = didStartPlayback
    ? observedAt
    : previous?.lastPlayedAt ?? (playing ? observedAt : 0);

  // isPiP feeds the priority pause-target selection (a PiP tab is what the user is watching). Track it
  // per tab so orderedDictationCandidates can promote it ahead of other playing tabs.
  tabPlayState.set(tabId, { lastPlayedAt, playing, title, url, isPiP: isPiP === true });
  persistTabPlayState();
};

/**
 * Build the ordered list of candidate tabs to pause for a dictation. `tabPlayState` supplies the
 * media state while a fresh chrome.tabs/windows query supplies user-attention signals. This matters
 * when several tabs really are playing: the active tab in Chrome's last-focused window is the video
 * Ethan is watching, whereas heartbeat timing is unrelated to user intent.
 *
 * PiP PRIORITY (2026-07-09 PiP fix): a tab whose video is in Picture-in-Picture is BY DEFINITION the
 * one the user is watching right now — regardless of whether its tab is hidden or most-recently-focused.
 * So PiP tabs are promoted ahead of ordinary playing tabs. And because a hidden PiP tab's play flag can
 * go STALE (heartbeats throttle to ~1/min when backgrounded, so a missed report can leave the cache
 * marking it "paused"), a PiP tab stays eligible even when the cache says not-playing AND even beyond
 * RECENT_PLAY_FALLBACK_MS — the content script re-checks the live <video> before actually pausing, so
 * targeting a genuinely-paused PiP tab is a safe reported no-op.
 * @returns {Promise<Array<{ tabId: number, lastPlayedAt: number, why: string }>>}
 */
const orderedDictationCandidates = async () => {
  const now = Date.now();
  let liveTabs = [];
  let lastFocusedWindowId = null;

  try {
    liveTabs = await chrome.tabs.query({ url: youtubeUrlPatterns });
  } catch {
    // The tracked-state tiers below still provide a safe fallback if the live query fails.
  }

  try {
    const lastFocusedWindow = await chrome.windows.getLastFocused();
    if (typeof lastFocusedWindow?.id === 'number') {
      lastFocusedWindowId = lastFocusedWindow.id;
    }
  } catch {
    // Chrome can briefly report no last-focused window while switching apps; active/audible still rank.
  }

  const liveTabsById = new Map(
    liveTabs
      .filter((tab) => typeof tab.id === 'number')
      .map((tab) => [tab.id, tab]),
  );
  const entriesById = new Map(
    [...tabPlayState.entries()].map(([tabId, state]) => [
      tabId,
      { tabId, ...state, liveTab: liveTabsById.get(tabId) },
    ]),
  );
  // A just-opened/activated YouTube tab can beat its first content-state report to this command. Add
  // live-only tabs as safe candidates: directional pause will confirm whether they are really playing.
  for (const [tabId, liveTab] of liveTabsById) {
    if (!entriesById.has(tabId)) {
      entriesById.set(tabId, {
        tabId,
        lastPlayedAt: 0,
        playing: false,
        title: liveTab.title ?? '',
        url: liveTab.url ?? '',
        isPiP: false,
        liveTab,
      });
    }
  }
  const entries = [...entriesById.values()];

  const toCandidate = (why) => (entry) => ({
    tabId: entry.tabId,
    lastPlayedAt: entry.lastPlayedAt,
    why,
  });
  const byRecency = (a, b) => b.lastPlayedAt - a.lastPlayedAt;
  const byLiveAttention = (a, b) =>
    (b.liveTab?.lastAccessed ?? 0) - (a.liveTab?.lastAccessed ?? 0) || byRecency(a, b);

  // Tier 0 — PiP + currently playing: the strongest possible signal for "pause this one first".
  const pipPlaying = entries
    .filter((entry) => entry.isPiP && entry.playing)
    .sort(byRecency)
    .map(toCandidate('pip-playing'));

  // Tier 1 — active YouTube tab in Chrome's last-focused window: this is the ordinary "video Ethan is
  // watching" case. Try it even if cached state says paused/missing; the content script's directional
  // command is the authoritative live check and safely no-ops before we continue to the next tier.
  const lastFocusedActive = entries
    .filter(
      (entry) =>
        entry.liveTab?.active === true &&
        entry.liveTab.windowId === lastFocusedWindowId,
    )
    .sort(byLiveAttention)
    .map(toCandidate('last-focused-active-live-check'));

  // Tier 2 — audible playing tabs. If the active Chrome tab is not YouTube, this finds the background
  // tab whose sound Ethan is actually hearing before considering silent autoplay/background videos.
  const audiblePlaying = entries
    .filter((entry) => entry.liveTab?.audible === true)
    .sort(byLiveAttention)
    .map(toCandidate('audible-playing'));

  // Tier 3 — active YouTube tab in any Chrome window. Useful if getLastFocused briefly returned none;
  // again the content script performs the live playing check, so a paused active tab is harmless.
  const activeEligible = entries
    .filter((entry) => entry.liveTab?.active === true)
    .sort(byLiveAttention)
    .map(toCandidate('active-live-check'));

  // Tier 4 — any currently-playing tab, using real playback-start recency only (heartbeats do not move it).
  const currentlyPlaying = entries
    .filter((entry) => entry.playing)
    .sort(byRecency)
    .map(toCandidate('currently-playing'));

  // Tier 5 — PiP tab whose cached flag is (possibly stale) not-playing: still eligible because PiP =
  // actively watched, no recency cap (see block comment). The content script guards against a false pause.
  const pipEligible = entries
    .filter((entry) => entry.isPiP && !entry.playing && entry.lastPlayedAt > 0)
    .sort(byRecency)
    .map(toCandidate('pip-eligible-stale-flag'));

  // Tier 6 — recently-played fallback (cache marks paused but it played within the window).
  const recentlyPlayed = entries
    .filter(
      (entry) =>
        !entry.playing &&
        entry.lastPlayedAt > 0 &&
        now - entry.lastPlayedAt <= RECENT_PLAY_FALLBACK_MS,
    )
    .sort(byRecency)
    .map(toCandidate('recently-played-fallback'));

  // De-dup by tabId keeping the highest-priority tier (a PiP-playing tab also appears in currentlyPlaying;
  // we want its front position + 'pip-playing' label).
  const seen = new Set();
  const ordered = [];
  for (const candidate of [
    ...pipPlaying,
    ...lastFocusedActive,
    ...audiblePlaying,
    ...activeEligible,
    ...currentlyPlaying,
    ...pipEligible,
    ...recentlyPlayed,
  ]) {
    if (seen.has(candidate.tabId)) {
      continue;
    }
    seen.add(candidate.tabId);
    ordered.push(candidate);
  }
  return ordered;
};

/**
 * Record a MANUAL (user-initiated) pause reported by a content script, and prune stale records.
 * We ALWAYS record (even when no dictation is active) because a manual pause can land a beat BEFORE
 * the dictation-start command arrives (Ethan hits spacebar, THEN triggers VoiceInk); the pending
 * record lets `pauseYouTubeForDictation` adopt it once the dictation actually starts.
 * @param {number} tabId
 * @param {number} timestamp  Content-script wall-clock ms for ordering against dictation start.
 */
const recordManualPause = (tabId, timestamp) => {
  recentManualPauses.set(tabId, timestamp);

  const cutoff = Date.now() - RECENT_MANUAL_PAUSE_PRUNE_MS;
  for (const [id, ts] of recentManualPauses) {
    if (ts < cutoff) {
      recentManualPauses.delete(id);
    }
  }

  persistRecentManualPauses();
};

/**
 * If a dictation is active and an unclaimed target slot exists, ADOPT a near-simultaneous manual
 * pause as the dictation's pause target so the dictation-stop resume plays it back.
 *
 * Called only when the manual pause happened just BEFORE dictation started and the start command
 * then finds nothing to pause. A manual Play/Pause after the start relinquishes playback ownership.
 *
 * Edge cases handled here:
 *   (a) don't clobber / double-adopt — bail if we already have a dictationPausedTabId.
 *   (b) leave deliberate pauses alone — only manual pauses within ±MANUAL_PAUSE_ADOPT_WINDOW_MS of
 *       the dictation start qualify; a pause well into a dictation is outside the window.
 *   (c) different tab than the most-recently-played target — PREFER the most-recently-played tab
 *       (that's the video tied to the dictation); fall back to the most-recent manual pause.
 * @returns {Promise<boolean>} true if a manual pause was adopted on THIS call.
 */
const maybeAdoptManualPause = async () => {
  // (b) No active dictation → these are ordinary manual pauses Ethan wants to keep paused. Leave them.
  if (!isDictationActive() || typeof dictationStartedAt !== 'number') {
    return false;
  }

  // (b') Staleness guard: if the "active" session actually started implausibly long ago it's a
  // stranded session (dropped stop), NOT the near-simultaneous case this feature targets — refuse to
  // adopt against an ancient start time (this is the exact bug the live log showed: adopt measured
  // against a 3-minute-old startedAt). The watchdog / next-start self-heal will clear the stale state.
  if (Date.now() - dictationStartedAt > MAX_DICTATION_MS) {
    return false;
  }

  // (a) Already have a target (we paused something, or already adopted) → never clobber it.
  if (typeof dictationPausedTabId === 'number') {
    return false;
  }

  // Keep only the just-BEFORE race: the old symmetric window adopted a manual pause after recording
  // started and later overrode Ethan by playing on stop.
  const nearby = [...recentManualPauses.entries()].filter(
    ([, ts]) => ts <= dictationStartedAt && dictationStartedAt - ts <= MANUAL_PAUSE_ADOPT_WINDOW_MS,
  );
  if (nearby.length === 0) {
    return false;
  }

  // (c) Prefer the most-recently-played tab (the one tied to this dictation, same selection logic as
  // the normal pause path) when it's among the manually-paused tabs; otherwise the most-recent pause.
  const preferredTabId = (await orderedDictationCandidates())[0]?.tabId;
  let chosen = nearby.find(([tabId]) => tabId === preferredTabId);
  if (!chosen) {
    chosen = [...nearby].sort((a, b) => b[1] - a[1])[0];
  }

  const [tabId, ts] = chosen;
  dictationPausedTabId = tabId;
  persistDictationPausedTabId();
  clog(
    'background',
    `adopted manual pause tab=${tabId} msSinceDictationStart=${ts - dictationStartedAt} — treating Ethan's near-simultaneous manual pause AS our dictation pause so the resume plays it back`,
  );
  return true;
};

/**
 * Handle a genuine manual Play/Pause. An action after recording starts permanently gives playback
 * control back to Ethan for that session; a stop still balances depth but never calls play or pause.
 * A pause just before the start retains the existing near-simultaneous adoption behavior.
 * @param {number | undefined} tabId
 * @param {'play' | 'pause'} action
 * @param {number | undefined} contentTimestamp
 * @returns {Promise<void>}
 */
const handleManualPlaybackControl = (tabId, action, contentTimestamp) => {
  if (typeof tabId !== 'number') {
    return;
  }

  void enqueueDictationOp(`manual-${action}`, async () => {
    await hydrateFromStorage(); // The MV3 worker may have slept since a dictation started — restore it.

    const now = Date.now();
    const actionAt = typeof contentTimestamp === 'number' ? contentTimestamp : now;

    clog(
      'background',
      `manual-${action} reported tab=${tabId} dictationActive=${isDictationActive()} dictationStartedAt=${dictationStartedAt ?? 'nil'} contentTs=${contentTimestamp ?? 'nil'}`,
    );

    if (isDictationActive() && typeof dictationStartedAt === 'number' && actionAt >= dictationStartedAt) {
      const previousTarget = dictationPausedTabId;
      dictationPlaybackRelinquished = true;
      dictationPausedTabId = null;
      dictationLastActivityAt = now;
      persistDictationPausedTabId();
      persistDictationState();
      clog('background', `manual-${action} RELINQUISHED playback control tab=${tabId} previousTarget=${previousTarget ?? 'nil'} — later recording stop will not play or pause`);
      return;
    }

    if (action === 'pause') {
      recordManualPause(tabId, actionAt);
      await maybeAdoptManualPause();
    }
  });
};

// -- Persistent log funnel -----------------------------------------------------------------------
//
// WHY: the Chrome extension used to be the diagnostic blind spot for the intermittent
// "second dictation didn't pause" flake — console.* logs vanish when the MV3 service worker sleeps
// or DevTools is closed. `clog` funnels every meaningful extension event to the native host as a
// `client-log` message, which writes it into the app's single log file
// (~/Library/Logs/youtube-spotify-media-key.log) so background + content-script + native-host +
// menu-bar events all interleave with timestamps in ONE tailable timeline.
//
// The tricky case is when the native port itself is DOWN (the "port dropped" hypothesis) — then the
// funnel can't reach the file. For that we ALSO keep a small ring buffer in chrome.storage.local
// (`clientLogRing`) as a backup; dump it any time with:
//   chrome.storage.local.get('clientLogRing', (r) => console.log(r.clientLogRing.join('\n')))
// from the extension's service-worker DevTools console.
const CLIENT_LOG_RING_MAX = 300;
let clientLogRing = [];

/**
 * @param {string} source  Which layer emitted the line ('background' or 'content').
 * @param {string} text     Human-readable event description (include tab id / url / state).
 */
const clog = (source, text) => {
  const line = `${new Date().toISOString()} [${source}] ${text}`;

  // Backup ring buffer first, so we still capture the event even if the native port is down.
  clientLogRing.push(line);
  if (clientLogRing.length > CLIENT_LOG_RING_MAX) {
    clientLogRing = clientLogRing.slice(-CLIENT_LOG_RING_MAX);
  }
  try {
    chrome.storage.local.set({ clientLogRing });
  } catch {
    // Storage is only a diagnostic backup; never let it break control flow.
  }

  // Funnel to the single app log file via the native host (log-only message type; the host writes
  // it and does NOT forward it to the menu-bar app). If the port is down this is a no-op — the ring
  // buffer above still has it.
  if (nativePort) {
    try {
      nativePort.postMessage({ type: 'client-log', reason: source, message: text });
    } catch {
      // Swallowed: a failed log post must never affect pause/resume behavior.
    }
  }

  console.debug('[yt-media-key]', line);
};

/**
 * @param {string} key
 * @param {Record<string, unknown>} value
 */
const rememberStatus = (key, value) => {
  statusState[key] = {
    ...value,
    extensionTimestamp: Date.now(),
  };

  try {
    chrome.storage.local.set({
      [key]: statusState[key],
    });
  } catch {
    // Storage is only diagnostic, so media-key routing should keep working if it is unavailable.
  }
};

const statusResponse = () => {
  try {
    return {
      ...JSON.parse(JSON.stringify(statusState)),
      backgroundTimestamp: Date.now(),
    };
  } catch {
    return {
      nativeConnection: {
        connected: false,
        message: 'status-serialization-failed',
        extensionTimestamp: Date.now(),
      },
      nativeStatus: null,
      lastYouTubeState: null,
      backgroundTimestamp: Date.now(),
    };
  }
};

const connectNativeHost = () => {
  if (nativePort) {
    return;
  }

  try {
    nativePort = chrome.runtime.connectNative(nativeHostName);
  } catch (error) {
    console.warn('Could not connect to native media-key host.', error);
    rememberStatus('nativeConnection', {
      connected: false,
      message: 'connect-failed',
      error: String(error),
    });
    scheduleNativeReconnect();
    return;
  }

  rememberStatus('nativeConnection', {
    connected: true,
    message: 'connected',
  });

  nativePort.onMessage.addListener((message) => {
    handleNativeMessage(message);
  });

  nativePort.onDisconnect.addListener(() => {
    const disconnectMessage = chrome.runtime.lastError?.message;
    nativePort = null;

    if (disconnectMessage) {
      console.warn('Native media-key host disconnected.', disconnectMessage);
    }

    // The port dying between a pause (record-start) and resume (record-stop) is one of the prime
    // suspects for the flake — log it. NB: nativePort is now null, so this clog line lands only in
    // the storage ring buffer, not the file, until the port reconnects.
    clog('background', `native port DISCONNECTED err="${disconnectMessage ?? ''}"`);

    rememberStatus('nativeConnection', {
      connected: false,
      message: 'disconnected',
      error: disconnectMessage ?? '',
    });
    scheduleNativeReconnect();
  });

  clog('background', 'native port CONNECTED (extension-ready)');

  postNativeMessage({
    type: 'extension-ready',
    extensionTimestamp: Date.now(),
  });
  void requestYouTubeStates(); // Rehydrates the native host after a restart so YouTube can reclaim ownership before the next heartbeat.
};

const scheduleNativeReconnect = () => {
  if (nativeReconnectTimeout !== undefined) {
    return;
  }

  // Fast reconnect while the worker is awake. NB: setTimeout does NOT survive service-worker
  // termination — if the worker suspends before this fires, the timer is lost. That gap is covered by
  // the always-on keep-warm alarm (FIX 3), whose onAlarm handler re-runs `if (!nativePort)
  // connectNativeHost()` on every tick, so the port is durably re-established even after a suspension.
  nativeReconnectTimeout = setTimeout(() => {
    nativeReconnectTimeout = undefined;
    connectNativeHost();
  }, 2000);
};

/**
 * @returns {Promise<void>}
 */
const waitForNextNativeStatus = () =>
  new Promise((resolve) => {
    let isResolved = false;
    const timeout = setTimeout(() => {
      resolveStatusRequest();
    }, 1000);

    const resolveStatusRequest = () => {
      if (isResolved) {
        return;
      }

      isResolved = true;
      clearTimeout(timeout);
      pendingNativeStatusResolvers = pendingNativeStatusResolvers.filter(
        (resolver) => resolver !== resolveStatusRequest,
      );
      resolve();
    };

    pendingNativeStatusResolvers.push(resolveStatusRequest);
  });

const resolvePendingNativeStatusRequests = () => {
  const resolvers = pendingNativeStatusResolvers;
  pendingNativeStatusResolvers = [];

  for (const resolveStatusRequest of resolvers) {
    resolveStatusRequest();
  }
};

/**
 * @param {Record<string, unknown>} message
 */
const postNativeMessage = (message) => {
  if (!nativePort) {
    connectNativeHost();
  }

  if (!nativePort) {
    return;
  }

  try {
    nativePort.postMessage(message);
  } catch (error) {
    console.warn('Failed to post native media-key message.', error);
  }
};

/**
 * @param {unknown} message
 */
const handleNativeMessage = (message) => {
  if (!message || typeof message !== 'object') {
    return;
  }

  const typedMessage = /** @type {{ type?: unknown; tabId?: unknown; reason?: unknown; seekSeconds?: unknown; volumeDelta?: unknown; holdToken?: unknown; playbackRate?: unknown; restorePlaybackRate?: unknown; holdLeaseMilliseconds?: unknown; tabHistoryDirection?: unknown; chromeWebsite?: unknown }} */ (message);

  switch (typedMessage.type) {
    case 'toggle-youtube':
      toggleYouTubeTab(
        typeof typedMessage.tabId === 'number' ? typedMessage.tabId : undefined,
      );
      return;

    // VoiceInk dictation triggers (directional pause/resume — see content-script.js for why these
    // are separate from the blind toggle). The menu-bar app NO LONGER decides which tab to target —
    // it just relays "pause the dictation target" / "resume the dictation target" with no tabId. The
    // EXTENSION picks the tab from live attention + playback state and remembers it, so the app can't
    // get confused across Ethan's ~5 tabs. See pauseYouTubeForDictation / resumeYouTubeForDictation.
    case 'pause-youtube': {
      // Serialized: a pause can never interleave with an in-flight resume/adopt (the async-overlap
      // corruption was a root cause of the flake). Record the arrival BEFORE queueing so an older,
      // slow resume can see that a new recording has already begun and avoid playing underneath it.
      const pauseReason = typeof typedMessage.reason === 'string' ? typedMessage.reason : 'pause';
      pendingPauseCommandCount += 1;
      void enqueueDictationOp('pause', async () => {
        try {
          await pauseYouTubeForDictation(pauseReason);
        } finally {
          pendingPauseCommandCount = Math.max(0, pendingPauseCommandCount - 1);
        }
      });
      return;
    }

    case 'resume-youtube': {
      const resumeReason = typeof typedMessage.reason === 'string' ? typedMessage.reason : 'resume';
      void enqueueDictationOp('resume', () => resumeYouTubeForDictation(resumeReason));
      return;
    }

    case 'finish-dictation-preserving-playback': {
      const finishReason = typeof typedMessage.reason === 'string'
        ? typedMessage.reason
        : 'finish-preserving-playback';
      void enqueueDictationOp('finish-preserving-playback', () =>
        finishDictationPreservingPlayback(finishReason));
      return;
    }

    case 'seek-youtube': {
      // Keep the native IPC narrow: Agentic Mouse sends exactly one five-second scrub ratchet, not
      // arbitrary page control. Ignore malformed/other values rather than extending the surface.
      if (typedMessage.seekSeconds !== -5 && typedMessage.seekSeconds !== 5) {
        clog('background', `seek-youtube rejected invalid seconds=${String(typedMessage.seekSeconds)}`);
        postNativeMessage({ type: 'youtube-seek-result', sought: false, seekSeconds: typedMessage.seekSeconds, reason: 'invalid-seek-contract' });
        return;
      }
      void seekYouTubeFiveSeconds(typedMessage.seekSeconds);
      return;
    }

    case 'adjust-youtube-volume': {
      if (typedMessage.volumeDelta !== -0.05 && typedMessage.volumeDelta !== 0.05) {
        clog('background', `adjust-youtube-volume rejected invalid delta=${String(typedMessage.volumeDelta)}`);
        postNativeMessage({ type: 'youtube-volume-result', volumeAdjusted: false, volumeDelta: typedMessage.volumeDelta, reason: 'invalid-volume-contract' });
        return;
      }
      void adjustYouTubeVolumeFivePercent(typedMessage.volumeDelta);
      return;
    }

    case 'navigate-chrome-tab-history': {
      if (typedMessage.tabHistoryDirection !== 'back' && typedMessage.tabHistoryDirection !== 'forward') {
        postNativeMessage({
          type: 'chrome-tab-history-result',
          tabHistoryMoved: false,
          tabHistoryDirection: typedMessage.tabHistoryDirection,
          reason: 'invalid-tab-history-direction',
        });
        return;
      }
      void chromeTabHistory.navigate(typedMessage.tabHistoryDirection).then((result) => {
        postNativeMessage({
          type: 'chrome-tab-history-result',
          tabHistoryMoved: result.moved,
          tabHistoryDirection: typedMessage.tabHistoryDirection,
          tabId: result.tabId,
          reason: result.reason,
        });
      });
      return;
    }

    case 'open-chrome-website': {
      void chromeWebsiteOpener.open(typedMessage.chromeWebsite).then((result) => {
        postNativeMessage({
          type: 'chrome-website-result',
          chromeWebsite: typeof typedMessage.chromeWebsite === 'string'
            ? typedMessage.chromeWebsite
            : undefined,
          chromeWebsiteOpened: result.opened,
          tabId: result.tabId,
          reason: result.reason,
        });
      });
      return;
    }

    case 'begin-youtube-speed-hold':
    case 'renew-youtube-speed-hold':
    case 'end-youtube-speed-hold': {
      const hasRestorePlaybackRate = typedMessage.restorePlaybackRate !== undefined;
      if (
        typeof typedMessage.holdToken !== 'string'
        || typedMessage.playbackRate !== 2
        || (hasRestorePlaybackRate && (
          typedMessage.type !== 'end-youtube-speed-hold'
          || typedMessage.restorePlaybackRate !== 1
        ))
        || !Number.isInteger(typedMessage.holdLeaseMilliseconds)
        || typedMessage.holdLeaseMilliseconds < 1_500
        || typedMessage.holdLeaseMilliseconds > 5_000
      ) {
        clog('background', `${String(typedMessage.type)} rejected invalid speed-hold contract`);
        postNativeMessage({
          type: 'youtube-speed-hold-result',
          speedHeld: false,
          playbackRate: 2,
          reason: 'invalid-speed-hold-contract',
        });
        return;
      }
      if (typedMessage.type === 'begin-youtube-speed-hold') {
        void enqueueAgenticMouseSpeedHoldOp('begin', () => beginYouTubeSpeedHold(
          typedMessage.holdToken,
          typedMessage.playbackRate,
          typedMessage.holdLeaseMilliseconds,
        ));
      } else if (typedMessage.type === 'renew-youtube-speed-hold') {
        void enqueueAgenticMouseSpeedHoldOp('renew', () => renewYouTubeSpeedHold(
          typedMessage.holdToken,
          typedMessage.playbackRate,
          typedMessage.holdLeaseMilliseconds,
        ));
      } else {
        void enqueueAgenticMouseSpeedHoldOp('end', () => endYouTubeSpeedHold(
          typedMessage.holdToken,
          typedMessage.playbackRate,
          typedMessage.holdLeaseMilliseconds,
          'physical-release',
          typedMessage.restorePlaybackRate,
        ));
      }
      return;
    }

    case 'host-status':
      rememberStatus('nativeStatus', typedMessage);
      resolvePendingNativeStatusRequests();
      return;

    default:
      console.warn('Unknown native media-key message.', message);
  }
};

/**
 * @param {number | undefined} preferredTabId
 */
const toggleYouTubeTab = async (preferredTabId) => {
  if (preferredTabId !== undefined && (await sendToggleToTab(preferredTabId))) {
    return;
  }

  const youtubeTabs = await chrome.tabs.query({ url: youtubeUrlPatterns });

  for (const tab of youtubeTabs) {
    if (typeof tab.id === 'number' && (await sendToggleToTab(tab.id))) {
      return;
    }
  }
};

/**
 * @param {number} tabId
 * @returns {Promise<boolean>}
 */
const sendToggleToTab = (tabId) =>
  new Promise((resolve) => {
    chrome.tabs.sendMessage(tabId, { type: 'toggle-youtube' }, () => {
      resolve(!chrome.runtime.lastError);
    });
  });

// -- VoiceInk directional pause/resume (extension-owned target selection) -----------------------
//
// These send the directional `pause-youtube` / `resume-youtube` command to the ONE tab the
// extension itself picks (pause) or previously remembered (resume). The content script only actuates
// in the correct direction (pause only if playing, resume only if paused), so a candidate that is
// already in the target state is a safe reported no-op.

/**
 * @param {number} tabId
 * @param {'pause-youtube' | 'resume-youtube'} type
 * @returns {Promise<{ delivered: boolean; response: Record<string, unknown> | null; reason: string }>}
 */
const sendDirectionalToTab = (tabId, type) =>
  new Promise((resolve) => {
    chrome.tabs.sendMessage(tabId, { type }, (response) => {
      if (chrome.runtime.lastError) {
        resolve({
          delivered: false,
          response: null,
          reason: chrome.runtime.lastError.message,
        });
        return;
      }

      resolve({
        delivered: true,
        response:
          response && typeof response === 'object'
            ? response
            : { ok: false, reason: 'missing-response' },
        reason: '',
      });
    });
  });

// Sleep helper for the resume backoff / settle windows. Kept local (background.js has no shared util).
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Send a directional command to a tab, injecting the content script FIRST (so a tab whose content-
 * script context was torn down — worker slept / tab frozen — still has a live listener), and if the
 * send reports no receiver, RE-INJECT and retry the SAME tab once before giving up on it.
 *
 * WHY (FIX 4 — pause-path resilience parity): the resume path already re-injects before every attempt,
 * but the PAUSE path used to message the candidate WITHOUT pre-injecting, and a tab whose context was
 * invalidated was silently skipped and permanently excluded from the fallback. So an invalidated script
 * on the CORRECT (currently-playing) tab could make pause skip it forever = "dictation didn't pause".
 * Pre-injecting (idempotent — content-script self-cleans its prior listeners) also nudges a frozen tab
 * awake. This brings pause to the same resilience as resume.
 * @param {number} tabId
 * @param {'pause-youtube' | 'resume-youtube'} type
 * @returns {Promise<{ delivered: boolean; response: Record<string, unknown> | null; reason: string }>}
 */
const sendDirectionalWithReinject = async (tabId, type) => {
  await injectContentScript(tabId);
  let result = await sendDirectionalToTab(tabId, type);

  // No receiver ⇒ the content-script context was likely invalidated (extension reload / tab churn).
  // Re-inject a fresh listener and retry the same tab ONCE — don't abandon the correct target on a
  // single transient "no receiving end" error.
  if (!result.delivered) {
    clog('background', `${type} tab=${tabId} not delivered ("${result.reason}") — re-injecting + retrying once`);
    await injectContentScript(tabId);
    result = await sendDirectionalToTab(tabId, type);
    clog('background', `${type} tab=${tabId} retry delivered=${result.delivered} reason="${result.reason}"`);
  }

  return result;
};

/**
 * Send one Agentic Mouse five-second scrub command. Reuse the content-script reinjection resilience used
 * by the dictation path, but keep it separate from dictation ownership/state.
 * @param {number} tabId
 * @returns {Promise<{ delivered: boolean; response: Record<string, unknown> | null; reason: string }>}
 */
const sendAgenticMouseOneShotWithReinject = async (tabId, message) => {
  await injectContentScript(tabId);
  const send = () => new Promise((resolve) => {
    chrome.tabs.sendMessage(tabId, message, (response) => {
      if (chrome.runtime.lastError) {
        resolve({ delivered: false, response: null, reason: chrome.runtime.lastError.message });
        return;
      }
      resolve({ delivered: true, response: response && typeof response === 'object' ? response : { ok: false, reason: 'missing-response' }, reason: '' });
    });
  });

  let result = await send();
  if (!result.delivered) {
    await injectContentScript(tabId);
    result = await send();
  }
  return result;
};

// Select a YouTube target exactly as the dictation bridge does: PiP, then the active tab in the
// last-focused Chrome window, audible, active, and true playback-start recency. Seeking never
// changes play state or activates a tab/window, and is deliberately not queued with dictation work.
const seekYouTubeFiveSeconds = async (seekSeconds) => {
  const candidates = await orderedDictationCandidates();
  for (const candidate of candidates) {
    const result = await sendAgenticMouseOneShotWithReinject(
      candidate.tabId,
      { type: 'seek-youtube', seekSeconds },
    );
    if (result.delivered && result.response?.sought === true) {
      clog('background', `seek-youtube chose tab=${candidate.tabId} why=${candidate.why}`);
      postNativeMessage({ type: 'youtube-seek-result', tabId: candidate.tabId, sought: true, seekSeconds, reason: candidate.why });
      return;
    }
  }
  clog('background', 'seek-youtube found no eligible video');
  postNativeMessage({ type: 'youtube-seek-result', sought: false, seekSeconds, reason: 'no-eligible-youtube-video' });
};

// Volume uses the same background-safe target ordering as scrub, but the content script accepts
// only a genuinely playing video. A paused active YouTube tab therefore cannot steal the command
// from the playing PiP/audible/recent target, and neither tab nor window is focused.
const adjustYouTubeVolumeFivePercent = async (volumeDelta) => {
  const candidates = await orderedDictationCandidates();
  for (const candidate of candidates) {
    const result = await sendAgenticMouseOneShotWithReinject(
      candidate.tabId,
      { type: 'adjust-youtube-volume', volumeDelta },
    );
    if (result.delivered && result.response?.volumeAdjusted === true) {
      clog('background', `adjust-youtube-volume chose tab=${candidate.tabId} why=${candidate.why} volume=${String(result.response.volume)}`);
      postNativeMessage({
        type: 'youtube-volume-result',
        tabId: candidate.tabId,
        volumeAdjusted: true,
        volumeDelta,
        volume: result.response.volume,
        muted: result.response.muted,
        reason: candidate.why,
      });
      return;
    }
  }
  clog('background', 'adjust-youtube-volume found no playing video');
  postNativeMessage({
    type: 'youtube-volume-result',
    volumeAdjusted: false,
    volumeDelta,
    reason: 'no-playing-youtube-video',
  });
};

const readAgenticMouseSpeedHold = async () => {
  try {
    const stored = await chrome.storage.local.get(AGENTIC_MOUSE_SPEED_HOLD_STORAGE_KEY);
    const hold = stored[AGENTIC_MOUSE_SPEED_HOLD_STORAGE_KEY];
    if (
      hold
      && typeof hold === 'object'
      && typeof hold.token === 'string'
      && Number.isInteger(hold.tabId)
    ) {
      return { token: hold.token, tabId: hold.tabId };
    }
  } catch {
    // The content-script lease is the safety owner if storage is unavailable.
  }
  return null;
};

const persistAgenticMouseSpeedHold = async (token, tabId) => {
  try {
    await chrome.storage.local.set({
      [AGENTIC_MOUSE_SPEED_HOLD_STORAGE_KEY]: { token, tabId },
    });
  } catch {
    // End can still broadcast the opaque token, and lease expiry remains fail-safe.
  }
};

const clearAgenticMouseSpeedHold = async (token) => {
  const current = await readAgenticMouseSpeedHold();
  if (current?.token !== token) {
    return;
  }
  try {
    await chrome.storage.local.remove(AGENTIC_MOUSE_SPEED_HOLD_STORAGE_KEY);
  } catch {
    // A stale storage row is harmless: every later command is token checked.
  }
};

const sendYouTubeSpeedHoldToTab = async (
  tabId,
  type,
  token,
  playbackRate,
  holdLeaseMilliseconds,
  injectFirst,
  restorePlaybackRate,
) => {
  if (injectFirst) {
    await injectContentScript(tabId);
  }
  const message = {
    type,
    holdToken: token,
    playbackRate,
    holdLeaseMilliseconds,
  };
  if (restorePlaybackRate !== undefined) {
    message.restorePlaybackRate = restorePlaybackRate;
  }
  const send = () => new Promise((resolve) => {
    chrome.tabs.sendMessage(tabId, message, (response) => {
      if (chrome.runtime.lastError) {
        resolve({ delivered: false, response: null, reason: chrome.runtime.lastError.message });
        return;
      }
      resolve({
        delivered: true,
        response: response && typeof response === 'object'
          ? response
          : { ok: false, speedHeld: false, reason: 'missing-response' },
        reason: '',
      });
    });
  });

  let result = await send();
  if (!result.delivered && !injectFirst) {
    // Re-injection runs the previous content script's cleanup first, which
    // restores any active rate before installing the fresh listener.
    await injectContentScript(tabId);
    result = await send();
  }
  return result;
};

const beginYouTubeSpeedHold = async (token, playbackRate, holdLeaseMilliseconds) => {
  const existing = await readAgenticMouseSpeedHold();
  if (existing?.token === token) {
    const result = await sendYouTubeSpeedHoldToTab(
      existing.tabId,
      'begin-youtube-speed-hold',
      token,
      playbackRate,
      holdLeaseMilliseconds,
      false,
      undefined,
    );
    if (result.response?.speedHeld === true) {
      postNativeMessage({
        type: 'youtube-speed-hold-result',
        tabId: existing.tabId,
        speedHeld: true,
        playbackRate: result.response.playbackRate,
        previousPlaybackRate: result.response.previousPlaybackRate,
        reason: 'duplicate-begin-renewed',
      });
      return;
    }
  } else if (existing) {
    await endYouTubeSpeedHold(
      existing.token,
      playbackRate,
      holdLeaseMilliseconds,
      'superseded-by-new-hold',
    );
  }

  const candidates = await orderedDictationCandidates();
  for (const candidate of candidates) {
    const result = await sendYouTubeSpeedHoldToTab(
      candidate.tabId,
      'begin-youtube-speed-hold',
      token,
      playbackRate,
      holdLeaseMilliseconds,
      true,
      undefined,
    );
    if (result.delivered && result.response?.speedHeld === true) {
      await persistAgenticMouseSpeedHold(token, candidate.tabId);
      clog('background', `youtube-speed-hold began tab=${candidate.tabId} why=${candidate.why}`);
      postNativeMessage({
        type: 'youtube-speed-hold-result',
        tabId: candidate.tabId,
        speedHeld: true,
        playbackRate: result.response.playbackRate,
        previousPlaybackRate: result.response.previousPlaybackRate,
        reason: candidate.why,
      });
      return;
    }
  }

  clog('background', 'youtube-speed-hold found no currently playing video');
  postNativeMessage({
    type: 'youtube-speed-hold-result',
    speedHeld: false,
    playbackRate,
    reason: 'no-playing-youtube-video',
  });
};

const renewYouTubeSpeedHold = async (token, playbackRate, holdLeaseMilliseconds) => {
  const existing = await readAgenticMouseSpeedHold();
  if (existing?.token !== token) {
    return;
  }
  const result = await sendYouTubeSpeedHoldToTab(
    existing.tabId,
    'renew-youtube-speed-hold',
    token,
    playbackRate,
    holdLeaseMilliseconds,
    false,
    undefined,
  );
  if (result.response?.speedHeld !== true) {
    clog('background', `youtube-speed-hold renewal failed tab=${existing.tabId} — lease will restore`);
    await clearAgenticMouseSpeedHold(token);
  }
};

const endYouTubeSpeedHold = async (
  token,
  playbackRate,
  holdLeaseMilliseconds,
  reason,
  restorePlaybackRate,
) => {
  const existing = await readAgenticMouseSpeedHold();
  let result = null;
  let tabId;
  if (existing?.token === token) {
    tabId = existing.tabId;
    result = await sendYouTubeSpeedHoldToTab(
      existing.tabId,
      'end-youtube-speed-hold',
      token,
      playbackRate,
      holdLeaseMilliseconds,
      false,
      restorePlaybackRate,
    );
  } else {
    // The MV3 worker or storage may have been reset while the page-level hold
    // survived. Broadcast only the opaque token; every other tab rejects it.
    const tabs = await chrome.tabs.query({ url: youtubeUrlPatterns });
    for (const tab of tabs) {
      if (typeof tab.id !== 'number') {
        continue;
      }
      const candidate = await sendYouTubeSpeedHoldToTab(
        tab.id,
        'end-youtube-speed-hold',
        token,
        playbackRate,
        holdLeaseMilliseconds,
        false,
        restorePlaybackRate,
      );
      if (candidate.response?.reason !== 'hold-token-mismatch') {
        result = candidate;
        tabId = tab.id;
        break;
      }
    }
  }
  await clearAgenticMouseSpeedHold(token);
  const response = result?.response;
  clog('background', `youtube-speed-hold ended tab=${tabId ?? 'nil'} reason=${reason} result=${response?.reason ?? result?.reason ?? 'lease-owned'}`);
  postNativeMessage({
    type: 'youtube-speed-hold-result',
    tabId,
    speedHeld: false,
    playbackRate: response?.playbackRate,
    previousPlaybackRate: response?.previousPlaybackRate,
    reason: response?.reason ?? reason,
  });
};

// Does this tab still exist? Used by the resume path to distinguish "delivery failed, retry" from
// "the tab Ethan paused was closed/navigated away, stop chasing it".
const isTabAlive = (tabId) =>
  new Promise((resolve) => {
    try {
      chrome.tabs.get(tabId, () => resolve(!chrome.runtime.lastError));
    } catch {
      resolve(false);
    }
  });

// Arm/clear the chrome.alarms watchdog that force-heals a stranded dictation (a dropped
// recordingStopped). chrome.alarms is the MV3-correct timer: unlike setTimeout it survives the
// service worker sleeping, which is exactly when a long transcription would strand the session.
const armDictationWatchdog = () => {
  try {
    chrome.alarms.create(DICTATION_WATCHDOG_ALARM, {
      periodInMinutes: DICTATION_WATCHDOG_PERIOD_MINUTES,
    });
  } catch {
    // Missing 'alarms' permission or API unavailable — the start-time self-heal still covers the
    // common case; the watchdog is the belt-and-braces layer.
  }
};

const clearDictationWatchdog = () => {
  try {
    chrome.alarms.clear(DICTATION_WATCHDOG_ALARM);
  } catch {
    // no-op
  }
};

// Arm the always-on keep-warm alarm (FIX 3). Idempotent — chrome.alarms.create with the same name just
// resets the schedule, so calling this on every SW startup path is safe. This is what stops the worker
// (and its child native host) from idle-suspending while Chrome is backgrounded.
const ensureKeepWarmAlarm = () => {
  try {
    chrome.alarms.create(KEEP_WARM_ALARM, { periodInMinutes: KEEP_WARM_PERIOD_MINUTES });
  } catch {
    // If alarms are unavailable the worker falls back to event-driven wakes; nothing else to do.
  }
};

// Resume backoff schedule: attempt immediately, then retry with growing gaps. Covers the coordinator-
// emphasised RESUME flakiness — a freshly-woken worker whose target tab is still spinning its media
// element back up, or whose first click was swallowed in a background/PiP tab.
const RESUME_RETRY_DELAYS_MS = [0, 300, 800, 1500];

/**
 * Resume a specific tab and CONFIRM playback actually resumed, retrying with backoff. Re-injects the
 * content script before each attempt because after a long transcription the target tab's content-
 * script context can be torn down (or the tab reloaded), which would otherwise make resume a silent
 * no-op — the single biggest resume-flake cause. Aborts if the dictation session was superseded
 * (token changed) so a stale retry can't fight a newer session.
 * @param {number} tabId
 * @param {number} sessionToken  The dictationSessionToken captured when this resume began.
 * @param {string} reason
 * @returns {Promise<{ resumed: boolean; reason: string; attempts: number }>}
 */
const resumeTabWithConfirmation = async (tabId, sessionToken, reason) => {
  for (let attempt = 0; attempt < RESUME_RETRY_DELAYS_MS.length; attempt += 1) {
    // Superseded-session guard: a new dictation started while we were retrying → stop; the new
    // session now owns pause/resume and our stale play would fight it.
    if (sessionToken !== dictationSessionToken) {
      clog(
        'background',
        `resume ABORT tab=${tabId} attempt=${attempt + 1} — session token changed (${sessionToken}→${dictationSessionToken}, superseded)`,
      );
      return { resumed: false, reason: 'session-superseded', attempts: attempt };
    }

    // Rapid stop→start: the new start is queued behind this serialized resume. Abort before actuating
    // play; otherwise the old resume can make the video audible during the new recording for the full
    // retry window before the queued pause gets a turn.
    if (pendingPauseCommandCount > 0) {
      clog(
        'background',
        `resume ABORT tab=${tabId} attempt=${attempt + 1} — ${pendingPauseCommandCount} newer pause command(s) queued`,
      );
      return { resumed: false, reason: 'superseded-by-queued-recording-start', attempts: attempt };
    }

    const delay = RESUME_RETRY_DELAYS_MS[attempt];
    if (delay > 0) {
      await sleep(delay);
    }

    // A new recording can arrive during the backoff itself, so check once more immediately before play.
    if (pendingPauseCommandCount > 0) {
      clog(
        'background',
        `resume ABORT tab=${tabId} after backoff — ${pendingPauseCommandCount} newer pause command(s) queued`,
      );
      return { resumed: false, reason: 'superseded-by-queued-recording-start', attempts: attempt };
    }

    // Guarantee a live content-script listener before sending resume (idempotent — the script self-
    // cleans its prior listeners on re-inject). This is what makes resume survive worker/tab churn.
    await injectContentScript(tabId);

    const result = await sendDirectionalToTab(tabId, 'resume-youtube');
    const resumed = result.response?.resumed === true;
    const responseReason = result.response?.reason ?? result.reason ?? '';
    const alreadyPlaying = responseReason === 'already-playing';
    clog(
      'background',
      `resume attempt=${attempt + 1}/${RESUME_RETRY_DELAYS_MS.length} tab=${tabId} reason="${reason}" delivered=${result.delivered} resumed=${resumed} respReason="${responseReason}"`,
    );

    // Confirmed playing now, OR it was already playing (Ethan resumed it himself, or it never paused)
    // — both mean "the video is playing", which is the goal. Not a failure.
    if (resumed || alreadyPlaying) {
      return {
        resumed: true,
        reason: alreadyPlaying ? 'already-playing' : 'resumed-confirmed',
        attempts: attempt + 1,
      };
    }

    // Delivery failed → the tab may be gone. If it truly no longer exists, stop retrying (can't
    // resume a closed/navigated tab); if it's alive, the retry loop will try again after backoff.
    if (!result.delivered) {
      const alive = await isTabAlive(tabId);
      if (!alive) {
        clog(
          'background',
          `resume GIVE-UP tab=${tabId} — target tab no longer exists (closed/navigated between pause and resume)`,
        );
        return { resumed: false, reason: 'target-tab-gone', attempts: attempt + 1 };
      }
    }
  }

  clog('background', `resume EXHAUSTED ${RESUME_RETRY_DELAYS_MS.length} attempts tab=${tabId} — still not confirmed playing`);
  return { resumed: false, reason: 'resume-unconfirmed', attempts: RESUME_RETRY_DELAYS_MS.length };
};

/**
 * Fallback: query EVERY open YouTube tab live and pause whichever one is actually playing. Used when
 * the tracked-candidate path (orderedDictationCandidates, built from possibly-stale tabPlayState after
 * a worker sleep) paused nothing — this catches the currently-playing tab whose cached play-state was
 * stale/missing, which was a "dictation didn't pause" cause. The content script pauses ONLY if the
 * video is genuinely playing, so pinging every tab is safe.
 * @param {Set<number>} alreadyTriedTabIds  Tabs the tracked path already attempted (skip them).
 * @returns {Promise<number | null>}  The tab id we paused, or null.
 */
const pauseAnyPlayingYouTubeTab = async (alreadyTriedTabIds) => {
  let tabs = [];
  let lastFocusedWindowId = null;
  try {
    tabs = await chrome.tabs.query({ url: youtubeUrlPatterns });
  } catch {
    return null;
  }

  try {
    const lastFocusedWindow = await chrome.windows.getLastFocused();
    if (typeof lastFocusedWindow?.id === 'number') {
      lastFocusedWindowId = lastFocusedWindow.id;
    }
  } catch {
    // Active/audible/lastAccessed ordering below still makes the fallback deterministic.
  }

  // Bug fix: chrome.tabs.query order is unspecified. The old fallback could therefore pause any
  // playing tab when cached state was missing; rank the same live attention signals as the main path.
  const candidateIds = tabs
    .sort((a, b) => {
      const attentionScore = (tab) =>
        (tab.active === true && tab.windowId === lastFocusedWindowId ? 4 : 0) +
        (tab.audible === true ? 2 : 0) +
        (tab.active === true ? 1 : 0);
      return attentionScore(b) - attentionScore(a) || (b.lastAccessed ?? 0) - (a.lastAccessed ?? 0);
    })
    .map((tab) => tab.id)
    .filter((tabId) => typeof tabId === 'number' && !alreadyTriedTabIds.has(tabId));

  for (const tabId of candidateIds) {
    // Inject-before-send + retry-once (FIX 4). Ensures a live listener even for tabs open before the
    // extension loaded, and recovers a tab whose context was invalidated.
    const result = await sendDirectionalWithReinject(tabId, 'pause-youtube');
    clog(
      'background',
      `pause FALLBACK try tab=${tabId} delivered=${result.delivered} paused=${result.response?.paused} reason="${result.response?.reason ?? result.reason ?? ''}"`,
    );
    if (result.response?.paused === true) {
      return tabId;
    }
  }

  return null;
};

/**
 * recordingStarted → pause the most-recently-played currently-playing YouTube tab and REMEMBER it as
 * the dictation target so the matching resume restores exactly it.
 *
 * Ref-counted: increments dictationDepth. The video stays paused across overlapping dictations and is
 * resumed only when depth returns to 0 (see resumeYouTubeForDictation). Self-heals a stranded prior
 * session (dropped stop) before starting fresh. The target is recomputed FRESH from live tab state so
 * a stale target from a previous dictation can never mislead this one; a live all-tabs fallback covers
 * the case where the cached play-state was stale after a worker sleep.
 * @param {string} reason  Diagnostic reason from the native host (e.g. 'voiceink-recording-started').
 * @returns {Promise<void>}
 */
const pauseYouTubeForDictation = async (reason) => {
  await hydrateFromStorage(); // MV3 worker may have slept since the last report — restore the map + session.

  // Self-heal: if we still think a session is active but it started implausibly long ago, the previous
  // recordingStopped was almost certainly dropped — reset before starting fresh so its stale target /
  // adopt-window can't corrupt THIS dictation (the exact 3-min-stale bug seen in the live log).
  if (isDictationActive() && dictationStartedAt !== null && Date.now() - dictationStartedAt > MAX_DICTATION_MS) {
    clog('background', `pause: prior session stale (${Date.now() - dictationStartedAt}ms old) — self-healing before new dictation`);
    resetDictationSession('stale-prior-session-on-new-start');
  }

  // Ref-count this dictation. Only the 0→1 edge starts a NEW session (fresh start time + token via
  // reset-on-idle); a 1→2 edge (overlap: 2nd dictation while 1st transcribes) keeps the existing
  // session so we don't re-pause a different tab or reset the adopt window.
  const wasIdle = dictationDepth === 0;
  dictationDepth += 1;
  const now = Date.now();
  if (wasIdle) {
    dictationStartedAt = now;
    dictationPlaybackRelinquished = false;
  }
  dictationLastActivityAt = now;
  persistDictationState();
  armDictationWatchdog(); // Ensure the stranded-session force-heal timer is running for this session.

  // Overlap case: we already paused a tab for this session. The video should already be paused; do a
  // defensive re-pause pass (in case a stray resume let it drift back to playing) but NEVER clobber
  // the original remembered target — resume must still play back the FIRST tab we paused.
  const hadTarget = typeof dictationPausedTabId === 'number';

  if (!wasIdle && dictationPlaybackRelinquished) {
    clog('background', `pause overlap NO-OP depth=${dictationDepth}: manual playback control already relinquished this session`);
    postPauseResult(null, null, false, 'playback-control-relinquished');
    return;
  }

  // Overlap / rapid restart: keep ownership of the ORIGINAL tab. The old defensive pass recomputed all
  // candidates and could pause a different background video while the remembered target was already
  // paused. Re-check only the owned target; `not-playing` is the expected healthy result.
  if (hadTarget) {
    const targetTabId = dictationPausedTabId;
    const result = await sendDirectionalWithReinject(targetTabId, 'pause-youtube');
    const responseReason = result.response?.reason ?? result.reason ?? '';
    const targetStillPaused = result.response?.paused === true || responseReason === 'not-playing';
    clog(
      'background',
      `pause overlap target-only tab=${targetTabId} depth=${dictationDepth} delivered=${result.delivered} pausedNow=${result.response?.paused} reason="${responseReason}" — never pausing another tab`,
    );
    postPauseResult(
      targetTabId,
      null,
      targetStillPaused,
      targetStillPaused ? 'overlap-kept-original-target' : 'overlap-target-unconfirmed',
    );
    return;
  }

  const candidates = await orderedDictationCandidates();
  clog(
    'background',
    `pause-for-dictation reason="${reason}" depth=${dictationDepth} hadTarget=${hadTarget ? dictationPausedTabId : 'no'} candidates=[${candidates
      .map((candidate) => `${candidate.tabId}@${candidate.lastPlayedAt}(${candidate.why})`)
      .join(', ')}]`,
  );

  const tried = new Set();
  for (const candidate of candidates) {
    tried.add(candidate.tabId);
    // FIX 4: inject-before-send + retry-once-on-no-receiver, matching the resume path's resilience, so
    // an invalidated content-script context on the correct tab can't make pause skip it.
    const result = await sendDirectionalWithReinject(candidate.tabId, 'pause-youtube');
    clog(
      'background',
      `pause try tab=${candidate.tabId} lastPlayedAt=${candidate.lastPlayedAt} why=${candidate.why} delivered=${result.delivered} paused=${result.response?.paused} reason="${result.response?.reason ?? result.reason ?? ''}"`,
    );

    if (result.response?.paused === true) {
      // Remember EXACTLY this tab (mirror to storage so a worker sleep between now and the resume
      // can't lose which video to restore).
      dictationPausedTabId = candidate.tabId;
      persistDictationPausedTabId();
      clog('background', `pause CHOSE tab=${candidate.tabId} why=${candidate.why} — remembered as dictation target`);
      postPauseResult(candidate.tabId, candidate.lastPlayedAt, true, `paused-${candidate.why}`);
      return;
    }
  }

  // LIVE FALLBACK: the tracked candidates paused nothing, but tabPlayState may be stale after a worker
  // sleep. Query every YouTube tab live and pause the one that is genuinely playing right now.
  const fallbackTabId = await pauseAnyPlayingYouTubeTab(tried);
  if (typeof fallbackTabId === 'number') {
    dictationPausedTabId = fallbackTabId;
    persistDictationPausedTabId();
    clog('background', `pause CHOSE (live fallback) tab=${fallbackTabId} — remembered as dictation target`);
    postPauseResult(fallbackTabId, null, true, 'paused-live-fallback');
    return;
  }

  // Still nothing playing → this is the accidental-manual-pause case: Ethan may have paused the video
  // himself a moment ago. Adopt that near-simultaneous manual pause as our target so the resume plays it.
  const adopted = await maybeAdoptManualPause();
  if (adopted && typeof dictationPausedTabId === 'number') {
    postPauseResult(dictationPausedTabId, null, true, 'adopted-manual-pause');
    return;
  }

  // Genuinely nothing to pause and nothing to adopt. Deliberately do NOT set a target (resume will
  // no-op). The ref count still stands so the matching stop balances it.
  clog('background', `pause NO-OP: no currently-playing YouTube tab to pause (reason="${reason}", depth=${dictationDepth})`);
  postPauseResult(null, null, false, 'no-youtube-tab-paused');
};

/**
 * recordingStopped → decrement the dictation ref count; when it returns to 0, resume EXACTLY the tab
 * we paused (with confirmation + retries) then reset the session. While depth is still >0 (an
 * overlapping dictation is still recording) we DEFER the resume so the video stays paused until the
 * LAST dictation ends — this is the overlapping-dictation fix.
 * @param {string} reason
 * @returns {Promise<void>}
 */
const resumeYouTubeForDictation = async (reason) => {
  await hydrateFromStorage(); // The worker may have slept between pause and resume — restore the session + target.

  // Balance the ref count. Floor at 0 so a stray/duplicate stop (or a stop whose start was dropped)
  // can't drive it negative and defer a real resume forever.
  const previousDepth = dictationDepth;
  dictationDepth = Math.max(0, dictationDepth - 1);
  dictationLastActivityAt = Date.now();
  persistDictationState();

  const tabId = dictationPausedTabId;
  clog(
    'background',
    `resume-for-dictation reason="${reason}" depthWas=${previousDepth} depthNow=${dictationDepth} target=${tabId ?? 'nil'}`,
  );

  // Overlap: another dictation is still recording → keep the video paused, defer resume until it ends.
  if (dictationDepth > 0) {
    clog('background', `resume DEFERRED: ${dictationDepth} dictation(s) still active — keeping video paused`);
    armDictationWatchdog(); // Re-arm so a dropped stop on the remaining session still force-heals.
    postResumeResult(tabId, false, 'deferred-overlapping-dictation');
    return;
  }

  // Depth is now 0 — this was the last outstanding dictation. Time to actually resume.
  if (dictationPlaybackRelinquished) {
    clog('background', 'resume NO-OP: Ethan manually changed playback after recording started');
    resetDictationSession('resume-playback-control-relinquished');
    clearDictationWatchdog();
    postResumeResult(null, false, 'playback-control-relinquished');
    return;
  }

  if (typeof tabId !== 'number') {
    // Nothing was paused for this session (e.g. no video was playing at any start) → nothing to resume.
    clog('background', 'resume NO-OP: no remembered dictation target');
    resetDictationSession('resume-no-target');
    clearDictationWatchdog();
    postResumeResult(null, false, 'no-dictation-target');
    return;
  }

  // Bulletproof resume: confirm playback actually resumed, retrying with backoff + re-injecting the
  // content script (covers worker/tab churn during a long transcription — the main resume-flake cause).
  const sessionToken = dictationSessionToken;
  const outcome = await resumeTabWithConfirmation(tabId, sessionToken, reason);
  clog(
    'background',
    `resume FINAL tab=${tabId} resumed=${outcome.resumed} reason="${outcome.reason}" attempts=${outcome.attempts}`,
  );

  // A new recording may have arrived while the content script was handling play(). Preserve the
  // remembered target and put it back into the paused state before yielding to that queued start.
  // Crucially, do NOT reset the session here: the queued pause adopts this same target and the later
  // matching stop remains responsible for resuming it.
  if (pendingPauseCommandCount > 0) {
    const repause = await sendDirectionalWithReinject(tabId, 'pause-youtube');
    const repauseReason = repause.response?.reason ?? repause.reason ?? '';
    clog(
      'background',
      `resume SUPERSEDED by ${pendingPauseCommandCount} queued start(s): target=${tabId} repauseDelivered=${repause.delivered} repaused=${repause.response?.paused} reason="${repauseReason}" — keeping target for rapid restart`,
    );
    postResumeResult(tabId, false, 'deferred-rapid-restart');
    return;
  }

  // Session over — clear everything + stop the watchdog (unless a newer session already superseded us,
  // in which case the token guard inside resetDictationSession's callers keeps things consistent).
  if (sessionToken === dictationSessionToken) {
    resetDictationSession(`resume-complete-${outcome.reason}`);
    clearDictationWatchdog();
  } else {
    clog('background', `resume: session superseded during resume — leaving newer session intact`);
  }

  postResumeResult(tabId, outcome.resumed, outcome.reason);
};

/**
 * Balance one VoiceInk recording edge without playing or pausing any YouTube tab.
 * Used only by the genuine Primary triple-click clipboard route. Overlapping
 * recordings retain the existing paused target for the remaining depth; the last
 * such finish clears ownership/watchdog state with zero content-script actuation.
 * @param {string} reason
 * @returns {Promise<void>}
 */
const finishDictationPreservingPlayback = async (reason) => {
  await hydrateFromStorage();

  const previousDepth = dictationDepth;
  dictationDepth = Math.max(0, dictationDepth - 1);
  dictationLastActivityAt = Date.now();
  persistDictationState();

  const tabId = dictationPausedTabId;
  clog(
    'background',
    `finish-preserving-playback reason="${reason}" depthWas=${previousDepth} depthNow=${dictationDepth} target=${tabId ?? 'nil'} playbackCommand=none`,
  );

  if (dictationDepth > 0) {
    armDictationWatchdog();
    postResumeResult(tabId, false, 'preserved-overlapping-dictation');
    return;
  }

  resetDictationSession('finish-preserving-playback');
  clearDictationWatchdog();
  postResumeResult(tabId, false, 'playback-preserved');
};

/**
 * @param {number | null} tabId          The tab the extension chose (null if nothing was paused).
 * @param {number | null} lastPlayedAt   The chosen tab's most-recently-played timestamp (diagnostic).
 * @param {boolean} paused
 * @param {string} reason
 */
const postPauseResult = (tabId, lastPlayedAt, paused, reason) => {
  postNativeMessage({
    type: 'youtube-pause-result',
    tabId,
    lastPlayedAt,
    paused,
    reason,
    extensionTimestamp: Date.now(),
  });
};

/**
 * @param {number | null} tabId
 * @param {boolean} resumed
 * @param {string} reason
 */
const postResumeResult = (tabId, resumed, reason) => {
  postNativeMessage({
    type: 'youtube-resume-result',
    tabId,
    resumed,
    reason,
    extensionTimestamp: Date.now(),
  });
};

/**
 * @param {number} tabId
 * @returns {Promise<void>}
 */
const injectContentScript = async (tabId) => {
  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      files: ['content-script.js'],
    });
  } catch (error) {
    console.debug('Could not inject YouTube media-key content script.', error);
  }
};

const injectIntoOpenYouTubeTabs = async () => {
  let youtubeTabs = [];

  try {
    youtubeTabs = await chrome.tabs.query({ url: youtubeUrlPatterns });
  } catch (error) {
    console.debug('Could not query YouTube tabs for media-key script injection.', error);
    return;
  }

  await Promise.all(
    youtubeTabs
      .map((tab) => tab.id)
      .filter((tabId) => typeof tabId === 'number')
      .map((tabId) => injectContentScript(tabId)),
  );
};

const requestYouTubeStates = async () => {
  let youtubeTabs = [];

  try {
    youtubeTabs = await chrome.tabs.query({ url: youtubeUrlPatterns });
  } catch (error) {
    console.debug('Could not query YouTube tabs for media-key status.', error);
    return;
  }

  await Promise.all(
    youtubeTabs
      .map((tab) => tab.id)
      .filter((tabId) => typeof tabId === 'number')
      .map(async (tabId) => {
        await injectContentScript(tabId);

        try {
          chrome.tabs.sendMessage(tabId, { type: 'state-request' }, () => {
            void chrome.runtime.lastError;
          });
        } catch {
          // The tab can disappear between query and message delivery.
        }
      }),
  );
};

/**
 * @param {string | undefined} url
 * @returns {boolean}
 */
const isYouTubeUrl = (url) => !!url && /^https?:\/\/([^/]+\.)?youtube\.com\//u.test(url);

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || typeof message !== 'object') {
    return false;
  }

  const typedMessage = /** @type {{ type?: unknown; refreshYouTube?: unknown; text?: unknown; playing?: unknown; isPiP?: unknown; reason?: unknown; title?: unknown; url?: unknown; action?: unknown; contentTimestamp?: unknown }} */ (message);

  switch (typedMessage.type) {
    case 'youtube-manual-playback-control': {
      const tabId = typeof sender.tab?.id === 'number' ? sender.tab.id : undefined;
      if (typedMessage.action !== 'play' && typedMessage.action !== 'pause') {
        return false;
      }
      void handleManualPlaybackControl(
        tabId,
        typedMessage.action,
        typeof typedMessage.contentTimestamp === 'number' ? typedMessage.contentTimestamp : undefined,
      );
      return false;
    }

    // Content-script log lines arrive here and get funneled to the single app log file (via the
    // native host). Tagged with the sender tab id so a specific YouTube tab's play/pause events and
    // pause/resume command handling are attributable in the timeline.
    case 'client-log': {
      const tabId = typeof sender.tab?.id === 'number' ? sender.tab.id : 'nil';
      clog('content', `tab=${tabId} ${typeof typedMessage.text === 'string' ? typedMessage.text : ''}`);
      return false;
    }

    case 'status-request':
      void (async () => {
        try {
          connectNativeHost();
          const nativeStatusWait = nativePort ? waitForNextNativeStatus() : Promise.resolve(); // Prevents the popup from rendering the stale startup permission status before the host reply arrives.
          postNativeMessage({
            type: 'status-request',
            extensionTimestamp: Date.now(),
          });
          if (typedMessage.refreshYouTube === true) {
            await requestYouTubeStates();
          }
          await nativeStatusWait;
        } catch (error) {
          rememberStatus('nativeConnection', {
            connected: false,
            message: 'status-request-failed',
            error: String(error),
          });
        }

        sendResponse(statusResponse());
      })();
      return true;

    case 'youtube-state': {
      if (typeof sender.tab?.id !== 'number') {
        return false;
      }

      // Feed the most-recently-played tracker (see the tabPlayState block comment). Transitions update
      // playback recency; heartbeats refresh only the live playing flag so their arbitrary arrival order
      // cannot steal target priority from the active tab.
      recordTabPlayState(
        sender.tab.id,
        typedMessage.playing === true,
        typeof typedMessage.title === 'string' ? typedMessage.title : sender.tab.title ?? '',
        typeof typedMessage.url === 'string' ? typedMessage.url : sender.tab.url ?? '',
        typedMessage.isPiP === true,
        typeof typedMessage.reason === 'string' ? typedMessage.reason : 'unknown',
        typeof typedMessage.contentTimestamp === 'number' ? typedMessage.contentTimestamp : undefined,
      );

      rememberStatus('lastYouTubeState', {
        ...message,
        tabId: sender.tab.id,
        title: sender.tab.title ?? '',
        url: sender.tab.url ?? '',
      });

      postNativeMessage({
        ...message,
        type: 'youtube-state',
        tabId: sender.tab.id,
        title: sender.tab.title ?? '',
        url: sender.tab.url ?? '',
        extensionTimestamp: Date.now(),
      });

      return false;
    }

    default:
      return false;
  }
});

// Watchdog: clear a stranded dictation session. Fires every DICTATION_WATCHDOG_PERIOD_MINUTES while
// armed. If a session has been "recording" longer than MAX_DICTATION_MS, the matching
// recordingStopped was probably dropped (DistributedNotificationCenter is lossy), but that is not
// permission to start playback. The old watchdog visibly resumed paused videos every four minutes;
// recovery now clears only bridge ownership and leaves the user's current play/pause state untouched.
// (Codex task: 01a039f7-873c-7c30-b3dc-af8a6724ace5)
chrome.alarms.onAlarm.addListener((alarm) => {
  // Keep-warm tick (FIX 3): the mere delivery of this alarm woke/kept the worker, which is the whole
  // point. Also ensure the native port is up — this is the DURABLE reconnect path (chrome.alarms
  // survive worker termination; the setTimeout in scheduleNativeReconnect does not). We log every tick
  // deliberately so the log proves the worker stayed warm (expect a line ~every 30s); the 30-day
  // self-prune keeps the file bounded. A gap between keep-warm ticks in the log = the worker was
  // suspended for that window = a dropped-command risk window, which is exactly what we're diagnosing.
  if (alarm.name === KEEP_WARM_ALARM) {
    const hadPort = !!nativePort;
    if (!nativePort) {
      connectNativeHost(); // Durable reconnect: re-establish the port (and its child native host) after a suspension.
    }
    clog('background', `keep-warm tick nativePort=${hadPort ? 'connected' : 'was-null→reconnecting'} dictationDepth=${dictationDepth}`);
    return;
  }

  if (alarm.name !== DICTATION_WATCHDOG_ALARM) {
    return;
  }

  void enqueueDictationOp('watchdog', async () => {
    await hydrateFromStorage();

    if (!isDictationActive()) {
      clearDictationWatchdog(); // No session in flight → stop the timer.
      return;
    }

    const startedAt = dictationStartedAt ?? Date.now();
    const sessionMs = Date.now() - startedAt;
    if (sessionMs <= MAX_DICTATION_MS) {
      return; // Still a plausibly-live dictation; leave it be.
    }

    clog(
      'background',
      `WATCHDOG stale-session cleanup: session running ${sessionMs}ms (> ${MAX_DICTATION_MS}) — clearing ownership without changing playback`,
    );

    resetDictationSession('watchdog-stale-session-cleanup');
    clearDictationWatchdog();
  });
});

chrome.tabs.onRemoved.addListener((tabId) => {
  void chromeTabHistory.removed(tabId);
  // Drop the closed tab from the most-recently-played tracker so it can never be picked as a
  // dictation target (and a recycled tab id can't inherit its stale lastPlayedAt).
  if (tabPlayState.delete(tabId)) {
    persistTabPlayState();
  }

  // If the tab we paused for the current dictation just closed, forget the target so the eventual
  // resume doesn't chase a dead / recycled tab id (the resume will then no-op cleanly — logged).
  if (dictationPausedTabId === tabId) {
    clog('background', `dictation target tab=${tabId} CLOSED mid-session — clearing target (resume will no-op)`);
    dictationPausedTabId = null;
    persistDictationPausedTabId();
  }

  // Drop any pending manual-pause record for the closed tab so a recycled tab id can't inherit it
  // and get spuriously adopted.
  if (recentManualPauses.delete(tabId)) {
    persistRecentManualPauses();
  }

  postNativeMessage({
    type: 'youtube-tab-closed',
    tabId,
    extensionTimestamp: Date.now(),
  });
});

chrome.tabs.onActivated.addListener((activeInfo) => {
  void chromeTabHistory.activated(activeInfo);
});

chrome.tabs.onReplaced.addListener((addedTabId, removedTabId) => {
  void chromeTabHistory.replaced(addedTabId, removedTabId);
});

chrome.windows.onRemoved.addListener((windowId) => {
  void chromeTabHistory.windowRemoved(windowId);
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status === 'complete' && isYouTubeUrl(tab.url)) {
    injectContentScript(tabId);
  }
});

chrome.runtime.onInstalled.addListener(() => {
  clog('background', 'service worker onInstalled — connecting native host + arming keep-warm alarm');
  ensureKeepWarmAlarm(); // FIX 3: keep the worker (and its child native host) alive across backgrounding.
  connectNativeHost();
  void injectIntoOpenYouTubeTabs();
});

chrome.runtime.onStartup.addListener(() => {
  clog('background', 'service worker onStartup — connecting native host + arming keep-warm alarm');
  ensureKeepWarmAlarm(); // FIX 3.
  connectNativeHost();
  void injectIntoOpenYouTubeTabs();
});

// Top-level service-worker evaluation. This runs every time Chrome (re)spawns the worker — including a
// wake from suspension driven by the keep-warm alarm — so logging here marks each worker lifecycle
// start in the timeline (a fresh "worker EVALUATED" line after a quiet gap = the worker had been
// suspended and just woke). Re-arm keep-warm here too so the alarm is guaranteed present on every wake.
clog('background', 'service worker EVALUATED (top-level) — arming keep-warm alarm + connecting native host');
ensureKeepWarmAlarm(); // FIX 3.
connectNativeHost();
void injectIntoOpenYouTubeTabs();
void chromeTabHistory.initialize();

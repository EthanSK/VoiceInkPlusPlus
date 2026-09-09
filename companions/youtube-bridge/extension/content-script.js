/* global chrome */

(() => {
  const cleanupKey = '__youtubeSpotifyMediaKeyBridgeCleanup';
  const previousCleanup = globalThis[cleanupKey];

  if (typeof previousCleanup === 'function') {
    previousCleanup(); // Bug fix: extension reloads need fresh listeners in already-open YouTube tabs; repro by reloading the unpacked extension, then seeing pause commands get no Chrome result.
  }

  /** @type {Array<() => void>} */
  const cleanupCallbacks = [];

  /** @type {HTMLVideoElement | null} */
  let currentVideo = null;
  let detachCurrentVideo = () => {};

  /** @type {string | null} */
  let lastStateKey = null;

  let lastUrl = location.href;

  /** @type {{ token: string, video: HTMLVideoElement, videoId: string, previousPlaybackRate: number } | null} */
  let activeAgenticMouseSpeedHold = null;
  /** @type {ReturnType<typeof setTimeout> | null} */
  let agenticMouseSpeedHoldExpiry = null;

  // -- Throttle-proof programmatic-vs-manual playback classification (FIX 2, 2026-07-09) ------------
  //
  // WHY the extension must tell these apart: an automatic VoiceInk pause/resume vs a user action
  // (spacebar, clicking the video, or an explicit bridge toggle). Both fire the SAME
  // <video> event. Manual play/pause changes get REPORTED to background so a recording immediately
  // gives playback ownership back to Ethan. Automatic VoiceInk pause/resume changes must not.
  //
  // THE BUG we're fixing: the previous design used a wall-clock grace window (a pause landing within
  // PROGRAMMATIC_PAUSE_GRACE_MS=700ms of our marker was "ours"). But Ethan runs ~12 YouTube tabs, so
  // the dictation TARGET tab is almost always HIDDEN (document.hidden=true) even when Chrome is
  // frontmost. In a hidden/background tab Chrome CLAMPS timers to >=1s (→ ~1/min "intensive throttling"
  // after 5min hidden) and the 'pause' event dispatch itself can be deferred. So our OWN dictation
  // pause's 'pause' event could land 2–24s after we actuated — far outside 700ms — and get
  // MISCLASSIFIED as a manual user pause (the live log showed 19 such mislabels, 743ms..24162ms), which
  // then polluted background's manual-pause adopt logic. Time simply cannot distinguish
  // "throttled-ours" from "manual".
  //
  // THE FIX: COUNT outstanding programmatic pauses with a token instead of timing them. markProgrammatic-
  // Pause() increments the counter right before we actuate a pause we caused; handlePauseEvent consumes
  // one token per 'pause' event. A pause event with NO outstanding token is a genuine manual pause, no
  // matter how long Chrome throttling delayed it. Leak guard: lastProgrammaticActuationAt + a max-age
  // sweep clears tokens whose 'pause' event never arrived (element torn down / navigation) so a stale
  // token can't swallow a real manual pause forever; the counter is also reset on video-binding change.
  let pendingProgrammaticPauses = 0;
  let pendingProgrammaticPlays = 0;
  let pendingExplicitUserPlaybackControls = 0;
  let lastProgrammaticActuationAt = 0;
  const PROGRAMMATIC_TOKEN_MAX_AGE_MS = 30000;

  // Call immediately BEFORE any extension-initiated action that WILL pause the video (i.e. only when the
  // video is actually playing and about to transition to paused — a no-op pause fires no event and must
  // NOT consume a token). Increments the outstanding-programmatic-pause count so the resulting delayed
  // 'pause' event is recognised as ours by handlePauseEvent, regardless of background-tab throttling.
  const markProgrammaticPause = () => {
    pendingProgrammaticPauses += 1;
    lastProgrammaticActuationAt = Date.now();
  };

  const markProgrammaticPlay = () => {
    pendingProgrammaticPlays += 1;
    lastProgrammaticActuationAt = Date.now();
  };

  const clearFailedProgrammaticPlay = (video) => {
    if (video.paused && pendingProgrammaticPlays > 0) {
      pendingProgrammaticPlays -= 1;
    }
  };

  const markExplicitUserPlaybackControl = () => {
    pendingExplicitUserPlaybackControls += 1;
  };

  const hasManualPlaybackIntent = () => {
    if (pendingExplicitUserPlaybackControls > 0) {
      pendingExplicitUserPlaybackControls -= 1;
      return true;
    }
    return navigator.userActivation?.isActive === true;
  };

  // -- Persistent log funnel (content-script side) ----------------------------------------------
  //
  // Ships a log line up to background.js, which funnels it to the native host and into the single
  // app log file. This is the layer that was previously invisible: we can now see the ACTUAL
  // `<video>.paused` value at the moment a pause/resume command is handled, which is exactly what's
  // needed to diagnose the back-to-back "second dictation didn't pause" race (did the video get
  // paused? was it already playing again from the previous resume? did the command even arrive?).
  //
  // videoId (the YouTube ?v= id) disambiguates which video the tab is on, since a single tab id can
  // navigate between videos. Kept short and cheap; never throws (media-key routing must not break if
  // logging fails).
  const currentVideoId = () => {
    try {
      const url = new URL(location.href);
      return url.pathname.match(/^\/shorts\/([^/]+)/)?.[1]
        ?? url.searchParams.get('v') ?? '(none)';
    } catch {
      return '(none)';
    }
  };

  /**
   * @param {string} text
   */
  const clog = (text) => {
    try {
      chrome.runtime.sendMessage(
        { type: 'client-log', text: `v=${currentVideoId()} ${text}` },
        () => {
          void chrome.runtime.lastError;
        },
      );
    } catch {
      // Extension context can be invalidated while a YouTube page stays alive; logging is best-effort.
    }
  };

  /**
   * @returns {HTMLVideoElement | null}
   */
  const getMainVideo = () => {
    // YouTube retains the hidden watch player before the Shorts player when
    // entering Shorts through site navigation. The first video can therefore
    // report a successful seek at time zero without touching the visible Short.
    const path = new URL(location.href).pathname;
    if (path.startsWith('/shorts/')) {
      const shortsVideo = document.querySelector(
        'ytd-shorts:not([hidden]) #shorts-player video.html5-main-video',
      );
      return shortsVideo instanceof HTMLVideoElement ? shortsVideo : null;
    }
    if (path === '/watch') {
      const watchVideo = document.querySelector(
        'ytd-watch-flexy:not([hidden]) #movie_player video.html5-main-video',
      );
      if (watchVideo instanceof HTMLVideoElement) return watchVideo;
    }
    const mainVideo = document.querySelector('video.html5-main-video');

    if (mainVideo instanceof HTMLVideoElement) {
      return mainVideo;
    }

    const fallbackVideo = document.querySelector('video');

    return fallbackVideo instanceof HTMLVideoElement ? fallbackVideo : null;
  };

  // -- Picture-in-Picture awareness (PiP pause/resume fix, 2026-07-09) ---------------------------
  //
  // THE BUG: when a YouTube video is popped into Picture-in-Picture, VoiceInk dictation stopped
  // pausing/resuming it. Two reasons, both rooted in the fact that the PiP <video> is NOT necessarily
  // the element document.querySelector('video.html5-main-video') returns:
  //   (1) ACTUATION target: the user can pop a watch-page video into PiP and then navigate the tab (or
  //       YouTube swaps in feed/preview <video> elements), so getMainVideo() can point at a DIFFERENT,
  //       non-PiP <video>. Pausing THAT one leaves the PiP video playing. document.pictureInPictureElement
  //       always points at the ACTUAL video in the PiP window, so it must be preferred.
  //   (2) STATE reporting: because a PiP tab is (almost always) hidden/backgrounded, if we report play
  //       state from the wrong (paused/absent) element the tab never gets flagged as "playing", so the
  //       background's most-recently-played target picker never selects it → the pause command never
  //       targets the PiP tab at all.
  //
  // FIX: a video in PiP is BY DEFINITION the one the user is watching. Prefer it as BOTH the actuation
  // target AND the element we read/report play-state from. document.pictureInPictureElement is a
  // standard DOM property (no extra permission) and is null when nothing is in PiP.

  /**
   * The <video> currently displayed in the browser's Picture-in-Picture window, if any.
   * @returns {HTMLVideoElement | null}
   */
  const getPictureInPictureVideo = () => {
    const pipElement = document.pictureInPictureElement;
    return pipElement instanceof HTMLVideoElement ? pipElement : null;
  };

  /**
   * The video this tab should actuate/report on: the PiP video if one exists (it's what the user is
   * watching, even when this tab is hidden and even if the in-page DOM navigated to another video),
   * otherwise the normal main-page video.
   * @returns {HTMLVideoElement | null}
   */
  const getActiveVideo = () => getPictureInPictureVideo() ?? getMainVideo();

  /**
   * @param {HTMLVideoElement} video
   * @returns {boolean}
   */
  const isVideoPlaying = (video) => !video.paused && !video.ended;

  const clearAgenticMouseSpeedHoldTimer = () => {
    if (agenticMouseSpeedHoldExpiry !== null) {
      clearTimeout(agenticMouseSpeedHoldExpiry);
      agenticMouseSpeedHoldExpiry = null;
    }
  };

  const restoreAgenticMouseSpeedHold = (token, reason, restorePlaybackRate) => {
    const hold = activeAgenticMouseSpeedHold;
    if (!hold || hold.token !== token) {
      return { ok: false, speedHeld: false, reason: 'hold-token-mismatch' };
    }
    clearAgenticMouseSpeedHoldTimer();
    activeAgenticMouseSpeedHold = null;
    const targetPlaybackRate = restorePlaybackRate ?? hold.previousPlaybackRate;
    hold.video.playbackRate = targetPlaybackRate;
    const restored = hold.video.playbackRate === targetPlaybackRate;
    clog(`youtube-speed-hold restored=${restored} target=${targetPlaybackRate} previous=${hold.previousPlaybackRate} reason=${reason}`);
    return {
      ok: restored,
      speedHeld: false,
      playbackRate: hold.video.playbackRate,
      previousPlaybackRate: hold.previousPlaybackRate,
      reason: restored ? reason : 'restore-failed',
    };
  };

  const armAgenticMouseSpeedHoldExpiry = (token, leaseMilliseconds) => {
    clearAgenticMouseSpeedHoldTimer();
    agenticMouseSpeedHoldExpiry = setTimeout(() => {
      restoreAgenticMouseSpeedHold(token, 'lease-expired');
    }, leaseMilliseconds);
  };

  const beginAgenticMouseSpeedHold = (token, playbackRate, leaseMilliseconds) => {
    const video = getActiveVideo();
    if (!video || !isVideoPlaying(video)) {
      return { ok: false, speedHeld: false, reason: 'no-playing-video' };
    }

    if (activeAgenticMouseSpeedHold?.token === token) {
      activeAgenticMouseSpeedHold.video.playbackRate = playbackRate;
      armAgenticMouseSpeedHoldExpiry(token, leaseMilliseconds);
      return {
        ok: true,
        speedHeld: true,
        playbackRate: activeAgenticMouseSpeedHold.video.playbackRate,
        previousPlaybackRate: activeAgenticMouseSpeedHold.previousPlaybackRate,
        reason: 'renewed-by-begin',
      };
    }

    if (activeAgenticMouseSpeedHold) {
      restoreAgenticMouseSpeedHold(activeAgenticMouseSpeedHold.token, 'superseded');
    }

    const previousPlaybackRate = video.playbackRate;
    activeAgenticMouseSpeedHold = { token, video, videoId: currentVideoId(), previousPlaybackRate };
    video.playbackRate = playbackRate;
    armAgenticMouseSpeedHoldExpiry(token, leaseMilliseconds);
    const speedHeld = video.playbackRate === playbackRate;
    clog(`youtube-speed-hold began held=${speedHeld} previous=${previousPlaybackRate} current=${video.playbackRate}`);
    return {
      ok: speedHeld,
      speedHeld,
      playbackRate: video.playbackRate,
      previousPlaybackRate,
      reason: speedHeld ? 'held' : 'set-rate-failed',
    };
  };

  const renewAgenticMouseSpeedHold = (token, playbackRate, leaseMilliseconds) => {
    const hold = activeAgenticMouseSpeedHold;
    if (!hold || hold.token !== token) {
      return { ok: false, speedHeld: false, reason: 'hold-token-mismatch' };
    }
    hold.video.playbackRate = playbackRate;
    armAgenticMouseSpeedHoldExpiry(token, leaseMilliseconds);
    return {
      ok: hold.video.playbackRate === playbackRate,
      speedHeld: hold.video.playbackRate === playbackRate,
      playbackRate: hold.video.playbackRate,
      previousPlaybackRate: hold.previousPlaybackRate,
      reason: 'renewed',
    };
  };

  /**
   * @param {string} reason
   */
  const sendState = (reason) => {
    // Read state from the ACTIVE video (PiP video preferred). This is what makes a playing PiP video —
    // in an otherwise-hidden tab — get reported as playing, so the background picks it as the pause target.
    const video = getActiveVideo();
    const playing = video ? isVideoPlaying(video) : false;
    const isPiP = getPictureInPictureVideo() !== null;
    // isPiP is part of the dedup key so entering/leaving PiP always forces a fresh report even when the
    // playing flag / url / title didn't change — otherwise the background would never learn this tab is
    // now the PiP tab (and thus the priority pause target) until the next throttled heartbeat.
    const stateKey = `${location.href}|${document.title}|${playing}|${isPiP}`;

    if (lastStateKey === stateKey && reason !== 'heartbeat') {
      return;
    }

    // Log real play/pause transitions (not the 5s heartbeats — those would flood the file). This is
    // what the menu-bar app's "is this tab playing?" cache is built from, so seeing exactly when a
    // tab flips playing/paused is central to diagnosing stale-state flakes.
    if (reason !== 'heartbeat' && lastStateKey !== stateKey) {
      clog(`state→ playing=${playing} isPiP=${isPiP} reason=${reason}`);
    }

    lastStateKey = stateKey;

    try {
      chrome.runtime.sendMessage(
        {
          type: 'youtube-state',
          playing,
          isPiP,
          reason,
          title: document.title,
          url: location.href,
          currentTime: video?.currentTime ?? null,
          duration:
            video && Number.isFinite(video.duration) ? video.duration : null,
          contentTimestamp: Date.now(),
        },
        () => {
          void chrome.runtime.lastError;
        },
      );
    } catch {
      // YouTube can keep this script alive briefly while Chrome reloads the extension.
    }
  };

  const reportManualPlaybackControl = (action, now) => {
    clog(`MANUAL ${action} detected (no programmatic token) — giving playback ownership back to Ethan`);
    try {
      chrome.runtime.sendMessage(
        { type: 'youtube-manual-playback-control', action, contentTimestamp: now },
        () => {
          void chrome.runtime.lastError;
        },
      );
    } catch {
      // Extension context can be invalidated while a YouTube page stays alive; best-effort only.
    }
  };

  const sweepStaleProgrammaticTokens = (now) => {
    if (
      (pendingProgrammaticPauses > 0 || pendingProgrammaticPlays > 0) &&
      now - lastProgrammaticActuationAt > PROGRAMMATIC_TOKEN_MAX_AGE_MS
    ) {
      clog(`stale programmatic playback token sweep: clearing pauses=${pendingProgrammaticPauses} plays=${pendingProgrammaticPlays} (lastActuation=${now - lastProgrammaticActuationAt}ms ago)`);
      pendingProgrammaticPauses = 0;
      pendingProgrammaticPlays = 0;
    }
  };

  const handlePlayEvent = () => {
    const now = Date.now();
    sendState('play');
    sweepStaleProgrammaticTokens(now);

    if (pendingProgrammaticPlays > 0) {
      pendingProgrammaticPlays -= 1;
      clog(`programmatic play confirmed (tokens left=${pendingProgrammaticPlays})`);
      return;
    }

    if (hasManualPlaybackIntent()) {
      reportManualPlaybackControl('play', now);
    } else {
      clog('page-driven play detected without user activation — keeping current dictation ownership');
    }
  };

  // Handle a <video> 'pause' event. Always report the state, then report a genuine user pause when
  // there is no outstanding VoiceInk programmatic-pause token.
  const handlePauseEvent = () => {
    const now = Date.now();

    sendState('pause');
    sweepStaleProgrammaticTokens(now);

    // Token present ⇒ this pause is OURS (a VoiceInk dictation pause), even if Chrome throttling delayed
    // the event by seconds. Consume one token and do NOT report it as manual. This is the core of FIX 2.
    if (pendingProgrammaticPauses > 0) {
      pendingProgrammaticPauses -= 1;
      clog(`programmatic pause confirmed (tokens left=${pendingProgrammaticPauses})`);
      return;
    }

    if (hasManualPlaybackIntent()) {
      reportManualPlaybackControl('pause', now);
    } else {
      clog('page-driven pause detected without user activation — keeping current dictation ownership');
    }
  };

  /**
   * @param {HTMLVideoElement | null} video
   */
  const attachToVideo = (video) => {
    if (currentVideo === video) {
      return;
    }

    detachCurrentVideo();
    detachCurrentVideo = () => {};
    currentVideo = video;

    // New <video> element ⇒ any outstanding programmatic-pause tokens belonged to the OLD element and
    // will never be consumed by a 'pause' event now. Reset so they can't misclassify the first manual
    // pause on the new element as ours. (FIX 2 leak guard, binding-change path.)
    pendingProgrammaticPauses = 0;
    pendingProgrammaticPlays = 0;
    pendingExplicitUserPlaybackControls = 0;
    if (!video) return;

    const listeners = [
      ['play', handlePlayEvent],
      ['playing', () => sendState('playing')],
      ['pause', handlePauseEvent],
      ['ended', () => sendState('ended')],
      ['emptied', () => sendState('emptied')],
      // PiP transitions fire on the <video> element. Report immediately (don't wait for the throttled
      // heartbeat) so the background learns this tab is now — or is no longer — the PiP tab, which drives
      // the priority pause-target selection. See getActiveVideo / orderedDictationCandidates.
      ['enterpictureinpicture', () => { clog('entered Picture-in-Picture'); sendState('enter-pip'); }],
      ['leavepictureinpicture', () => { clog('left Picture-in-Picture'); sendState('leave-pip'); }],
    ];

    for (const [eventName, listener] of listeners) {
      video.addEventListener(eventName, listener);
    }
    detachCurrentVideo = () => {
      for (const [eventName, listener] of listeners) {
        video.removeEventListener(eventName, listener);
      }
    };

    sendState('video-attached');
  };

  // Bind to the ACTIVE video (PiP-preferred). On YouTube the PiP element is normally the same
  // html5-main-video element, so this is usually a no-op vs getMainVideo(); but if the user navigated
  // the tab while a video stayed in PiP, this keeps our listeners on the element actually being watched.
  const refreshVideoBinding = () => {
    const video = getActiveVideo();
    const hold = activeAgenticMouseSpeedHold;
    // Shorts may replace or reuse the video element between clips. A lease
    // belongs to the clip selected at press time, never to the next clip.
    if (hold && (hold.video !== video || (
      getPictureInPictureVideo() !== hold.video && hold.videoId !== currentVideoId()
    ))) {
      restoreAgenticMouseSpeedHold(hold.token, 'video-changed');
    }
    attachToVideo(video);
  };

  /**
   * @param {number} duration
   * @returns {Promise<void>}
   */
  const sleep = (duration) =>
    new Promise((resolve) => {
      window.setTimeout(resolve, duration);
    });

  /**
   * @param {Promise<unknown>} promise
   * @param {number} duration
   * @returns {Promise<void>}
   */
  const waitForPlayAttempt = async (promise, duration) => {
    try {
      await Promise.race([promise, sleep(duration)]);
    } catch {
      // The menu-bar app verifies by observed YouTube state and retries; a rejected play() is diagnostic, not fatal here.
    }
  };

  /**
   * @returns {Promise<{ ok: boolean; reason?: string }>}
   */
  const toggleYouTube = async () => {
    const video = getActiveVideo();

    if (!video) {
      return { ok: false, reason: 'no-video' };
    }

    markExplicitUserPlaybackControl();

    // FIX 1: actuate the media element DIRECTLY (reliable even in a hidden/throttled background tab,
    // where a .ytp-play-button click can be swallowed). YouTube's player syncs its own button UI from
    // the media element's play/pause events, so the on-screen control stays consistent.
    if (video.paused || video.ended) {
      await waitForPlayAttempt(video.play(), 300);
    } else {
      video.pause();
    }

    if (pendingExplicitUserPlaybackControls > 0) {
      pendingExplicitUserPlaybackControls -= 1;
    }

    sendState('native-toggle');

    return { ok: true };
  };

  // -- Directional pause / resume (added for the VoiceInk dictation trigger) ---------------------
  //
  // Why these exist separately from `toggle-youtube`:
  //   `toggle-youtube` is idempotent-blind — it flips whatever the current play state is. That is
  //   correct for a hardware media key (the user is deliberately toggling). But the VoiceInk
  //   "pause while I dictate, resume when I'm done" flow MUST be directional, otherwise a toggle
  //   on stop could *start* a video that the user had manually paused mid-dictation. So the menu
  //   bar app sends an explicit `pause-youtube` on record-start and an explicit `resume-youtube`
  //   on record-stop, and we only act if the video is actually in the opposite state.
  //
  // `pause-youtube`: pause ONLY if the video is currently playing. Reports back via the response
  //   `paused: true` so the menu bar app can record "we paused this tab" and know whether to
  //   resume it later (the "only resume what we paused" guard lives in the menu bar app).
  //
  // `resume-youtube`: play ONLY if the video is currently paused/ended. We use the player button
  //   first (same reason as toggle) so YouTube's UI state stays consistent.

  /**
   * @returns {Promise<{ ok: boolean; paused?: boolean; reason?: string }>}
   */
  const pauseYouTube = async () => {
    // Prefer the PiP video: a video in Picture-in-Picture is the one the user is watching, and calling
    // .pause() on the underlying media element pauses it even while it's in the PiP window (the element
    // stays in the DOM; PiP is just an alternate presentation surface). This is the core PiP actuation fix.
    const video = getActiveVideo();
    const isPiP = getPictureInPictureVideo() !== null;

    if (!video) {
      clog('pause-youtube received: NO VIDEO ELEMENT');
      return { ok: false, paused: false, reason: 'no-video' };
    }

    clog(`pause-youtube received: isPiP=${isPiP} video.paused=${video.paused} ended=${video.ended} playing=${isVideoPlaying(video)}`);

    // Only pause if it's genuinely playing; if it was already paused we report paused:false so the
    // menu bar app does NOT remember this tab as "we paused it" (and therefore won't resume it).
    // NB (flake diagnosis): in the back-to-back case, if the previous dictation's RESUME hasn't
    // actuated yet, the video is momentarily still paused here → we report not-playing → the new
    // pause no-ops → the late resume then plays it = "second dictation didn't pause". This log line
    // makes that sequence visible.
    if (!isVideoPlaying(video)) {
      return { ok: true, paused: false, reason: 'not-playing' };
    }

    // FIX 1 (kill the actuation latency): pause the media element DIRECTLY and FIRST. The old code
    // clicked .ytp-play-button, then `await sleep(150)`, then maybe a fallback video.pause(). In a
    // hidden/background tab (the common case — Ethan has ~12 YT tabs so the dictation target is almost
    // always hidden) Chrome clamps that setTimeout to seconds and frequently swallows the button click,
    // stretching the nominal 150ms to 2–24s. video.pause() on the media element is NOT throttled and
    // pauses synchronously regardless of tab visibility, collapsing the round-trip to ~1ms. Mark the
    // programmatic-pause token BEFORE actuating so the resulting 'pause' event is classified as ours.
    markProgrammaticPause();
    video.pause(); // Works on the PiP element too — pausing the media element pauses the PiP window.

    // Synchronous verdict: video.paused flips immediately on pause() (the 'pause' EVENT is what can be
    // deferred, not the property). So we can read the outcome right now with no settle sleep.
    const paused = !isVideoPlaying(video);

    // YouTube syncs its own .ytp-play-button UI from the media element's pause event, so no button
    // click is needed. sendState reports the new play state to background (fires the transition log).
    sendState('voiceink-pause');

    clog(`pause-youtube result (fast path): isPiP=${isPiP} paused=${paused} (video.paused=${video.paused})`);
    return { ok: true, paused };
  };

  /**
   * @returns {Promise<{ ok: boolean; resumed?: boolean; reason?: string }>}
   */
  const resumeYouTube = async () => {
    // Prefer the PiP video (same rationale as pauseYouTube): resume the exact element the user is
    // watching in the PiP window, not a stray in-page <video>.
    const video = getActiveVideo();
    const isPiP = getPictureInPictureVideo() !== null;

    if (!video) {
      clog('resume-youtube received: NO VIDEO ELEMENT');
      return { ok: false, resumed: false, reason: 'no-video' };
    }

    clog(`resume-youtube received: isPiP=${isPiP} video.paused=${video.paused} ended=${video.ended} playing=${isVideoPlaying(video)}`);

    // Only resume if it's currently paused/ended. If the user already started something playing
    // again during dictation, we leave it alone (don't double-trigger / steal their play state).
    if (isVideoPlaying(video)) {
      return { ok: true, resumed: false, reason: 'already-playing' };
    }

    // FIX 1 (kill the actuation latency): play the media element DIRECTLY and FIRST. The old code led
    // with a .ytp-play-button click + 150/250/400ms settle sleeps — all throttled to seconds in a
    // hidden/background tab (the common case here). video.play() actuates the media element with no
    // timer dependency. It returns a promise that can reject in a background/PiP tab, so race it with a
    // short cap so a hung promise can't stall us; the isVideoPlaying() check below is the real verdict.
    markProgrammaticPlay();
    await waitForPlayAttempt(video.play(), 300); // video.play() resumes the PiP element too.
    clearFailedProgrammaticPlay(video);
    if (isVideoPlaying(video)) {
      clog(`resume-youtube CONFIRMED playing (fast path) isPiP=${isPiP}`);
      sendState('voiceink-resume');
      return { ok: true, resumed: true };
    }

    // Fallback ONLY if the direct play() didn't take (rare — e.g. the media element was still tearing
    // down/spinning up). A couple more attempts alternating button-click and video.play() with a small
    // settle. The BACKGROUND layer ALSO retries the whole command with re-injection, so this just
    // covers the fast in-content recovery before we bounce back.
    const playButton = video.closest('.html5-video-player')?.querySelector('.ytp-play-button');
    const RESUME_FALLBACK_ATTEMPTS = [
      { useButton: true, settleMs: 200 },
      { useButton: false, settleMs: 300 },
    ];

    for (let i = 0; i < RESUME_FALLBACK_ATTEMPTS.length; i += 1) {
      const attempt = RESUME_FALLBACK_ATTEMPTS[i];

      if (attempt.useButton && playButton instanceof HTMLElement) {
        markProgrammaticPlay();
        playButton.click();
      } else {
        markProgrammaticPlay();
        await waitForPlayAttempt(video.play(), 300);
      }

      await sleep(attempt.settleMs);
      clearFailedProgrammaticPlay(video);

      if (isVideoPlaying(video)) {
        clog(`resume-youtube CONFIRMED playing after fallback attempt ${i + 1}/${RESUME_FALLBACK_ATTEMPTS.length}`);
        sendState('voiceink-resume');
        return { ok: true, resumed: true };
      }

      clog(`resume-youtube fallback attempt ${i + 1}/${RESUME_FALLBACK_ATTEMPTS.length} not yet playing (video.paused=${video.paused})`);
    }

    sendState('voiceink-resume');

    // Still not playing after all in-content attempts. Report resumed=false so the BACKGROUND layer
    // retries the whole command (re-injecting this script first, in case the tab churned). Not fatal.
    const resumed = isVideoPlaying(video);
    clog(`resume-youtube result: resumed=${resumed} (video.paused=${video.paused}) — exhausted in-content attempts`);
    return { ok: true, resumed, reason: resumed ? undefined : 'in-content-attempts-exhausted' };
  };

  // Agentic Mouse's five-second scrub command. This touches only the chosen <video>'s timeline:
  // it never focuses Chrome, activates a tab, changes playback state, or synthesizes a key/click.
  const seekYouTubeFiveSeconds = (seekSeconds) => {
    const video = getActiveVideo();
    if (!video) {
      return { ok: false, sought: false, reason: 'no-video' };
    }

    const previousTime = Number.isFinite(video.currentTime) ? video.currentTime : 0;
    const duration = Number.isFinite(video.duration) ? video.duration : Number.POSITIVE_INFINITY;
    const targetTime = Math.min(duration, Math.max(0, previousTime + seekSeconds));
    video.currentTime = targetTime;
    const sought = video.currentTime === targetTime;
    clog(`seek-youtube received: seconds=${seekSeconds} previous=${previousTime} current=${video.currentTime} sought=${sought}`);
    return { ok: sought, sought, reason: sought ? undefined : 'seek-failed' };
  };

  const adjustYouTubeVolumeFivePercent = (volumeDelta) => {
    const video = getActiveVideo();
    if (!video || !isVideoPlaying(video)) {
      return { ok: false, volumeAdjusted: false, reason: 'no-playing-video' };
    }

    const previousVolume = Number.isFinite(video.volume) ? video.volume : 1;
    const targetVolume = Math.min(1, Math.max(0, previousVolume + volumeDelta));
    video.volume = targetVolume;
    if (volumeDelta > 0 && video.muted) {
      video.muted = false;
    }
    const volumeAdjusted = video.volume === targetVolume && (volumeDelta < 0 || !video.muted);
    clog(`adjust-youtube-volume received: delta=${volumeDelta} previous=${previousVolume} current=${video.volume} muted=${video.muted} adjusted=${volumeAdjusted}`);
    return {
      ok: volumeAdjusted,
      volumeAdjusted,
      volume: video.volume,
      muted: video.muted,
      reason: volumeAdjusted ? undefined : 'volume-adjustment-failed',
    };
  };

  const handleRuntimeMessage = (message, _sender, sendResponse) => {
    if (!message || typeof message !== 'object') {
      return false;
    }
    refreshVideoBinding();

    const typedMessage = /** @type {{ type?: unknown, seekSeconds?: unknown, volumeDelta?: unknown, holdToken?: unknown, playbackRate?: unknown, restorePlaybackRate?: unknown, holdLeaseMilliseconds?: unknown }} */ (message);

    switch (typedMessage.type) {
      case 'state-request':
        sendState('state-request');
        sendResponse({ ok: true });
        return false;

      case 'toggle-youtube':
        toggleYouTube()
          .then((response) => sendResponse(response))
          .catch((error) =>
            sendResponse({ ok: false, reason: String(error) }),
          );
        return true;

      case 'pause-youtube':
        // VoiceInk record-start: pause only if playing. Response carries `paused` so the
        // background/menu-bar layers know whether this tab should be remembered for resume.
        pauseYouTube()
          .then((response) => sendResponse(response))
          .catch((error) =>
            sendResponse({ ok: false, paused: false, reason: String(error) }),
          );
        return true;

      case 'resume-youtube':
        // VoiceInk record-stop: resume only if currently paused. Response carries `resumed`.
        resumeYouTube()
          .then((response) => sendResponse(response))
          .catch((error) =>
            sendResponse({ ok: false, resumed: false, reason: String(error) }),
          );
        return true;

      case 'seek-youtube':
        if (typedMessage.seekSeconds !== -5 && typedMessage.seekSeconds !== 5) {
          sendResponse({ ok: false, sought: false, reason: 'invalid-seek-contract' });
          return false;
        }
        sendResponse(seekYouTubeFiveSeconds(typedMessage.seekSeconds));
        return false;

      case 'adjust-youtube-volume':
        if (typedMessage.volumeDelta !== -0.05 && typedMessage.volumeDelta !== 0.05) {
          sendResponse({ ok: false, volumeAdjusted: false, reason: 'invalid-volume-contract' });
          return false;
        }
        sendResponse(adjustYouTubeVolumeFivePercent(typedMessage.volumeDelta));
        return false;

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
          sendResponse({ ok: false, speedHeld: false, reason: 'invalid-speed-hold-contract' });
          return false;
        }
        if (typedMessage.type === 'begin-youtube-speed-hold') {
          sendResponse(beginAgenticMouseSpeedHold(
            typedMessage.holdToken,
            typedMessage.playbackRate,
            typedMessage.holdLeaseMilliseconds,
          ));
        } else if (typedMessage.type === 'renew-youtube-speed-hold') {
          sendResponse(renewAgenticMouseSpeedHold(
            typedMessage.holdToken,
            typedMessage.playbackRate,
            typedMessage.holdLeaseMilliseconds,
          ));
        } else {
          sendResponse(restoreAgenticMouseSpeedHold(
            typedMessage.holdToken,
            hasRestorePlaybackRate ? 'double-click-normal-speed' : 'physical-release',
            typedMessage.restorePlaybackRate,
          ));
        }
        return false;
      }

      default:
        return false;
    }
  };

  chrome.runtime.onMessage.addListener(handleRuntimeMessage);
  cleanupCallbacks.push(() => {
    if (activeAgenticMouseSpeedHold) {
      restoreAgenticMouseSpeedHold(activeAgenticMouseSpeedHold.token, 'content-script-cleanup');
    }
    try {
      chrome.runtime.onMessage.removeListener(handleRuntimeMessage);
    } catch {
      // Chrome can invalidate the extension context while a YouTube page stays alive.
    }
  });

  const observer = new MutationObserver(() => {
    refreshVideoBinding();
  });

  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['hidden', 'aria-hidden'],
  });
  cleanupCallbacks.push(() => observer.disconnect());

  const heartbeatTimer = window.setInterval(() => {
    refreshVideoBinding();
    if (lastUrl !== location.href) {
      lastUrl = location.href;
      refreshVideoBinding();
      sendState('url-change');
      return;
    }

    sendState('heartbeat');
  }, 5000);
  cleanupCallbacks.push(() => window.clearInterval(heartbeatTimer));
  cleanupCallbacks.push(() => detachCurrentVideo());

  const cleanup = () => {
    while (cleanupCallbacks.length > 0) {
      cleanupCallbacks.pop()?.();
    }
  };

  globalThis[cleanupKey] = cleanup;

  refreshVideoBinding();
})();

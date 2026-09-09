import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const contentSource = fs.readFileSync(
  new URL('../extension/content-script.js', import.meta.url),
  'utf8',
);
const backgroundSource = fs.readFileSync(
  new URL('../extension/background.js', import.meta.url),
  'utf8',
);

class FakeVideo extends EventTarget {
  constructor() {
    super();
    this.paused = false;
    this.ended = false;
    this.playbackRate = 1;
    this.currentTime = 30;
    this.duration = 120;
  }

  play() {
    this.paused = false;
    this.dispatchEvent(new Event('play'));
    return Promise.resolve();
  }

  pause() {
    this.paused = true;
    this.dispatchEvent(new Event('pause'));
  }
}

const video = new FakeVideo();
const sentMessages = [];
const userActivation = { isActive: false };
let runtimeListener;
const context = vm.createContext({
  console,
  Date,
  Event,
  EventTarget,
  HTMLVideoElement: FakeVideo,
  MutationObserver: class {
    observe() {}
    disconnect() {}
  },
  Promise,
  URL,
  clearTimeout,
  document: {
    title: 'Test video',
    documentElement: {},
    pictureInPictureElement: null,
    querySelector: () => video,
  },
  location: { href: 'https://www.youtube.com/watch?v=test' },
  navigator: { userActivation },
  setTimeout,
  window: {
    clearInterval: () => {},
    setInterval: () => 1,
  },
  chrome: {
    runtime: {
      lastError: undefined,
      sendMessage: (message, callback) => {
        sentMessages.push(message);
        callback?.();
      },
      onMessage: {
        addListener: (listener) => { runtimeListener = listener; },
        removeListener: () => {},
      },
    },
  },
});

vm.runInContext(contentSource, context, { filename: 'content-script.js' });
assert.equal(typeof runtimeListener, 'function');

const send = (type) => new Promise((resolve, reject) => {
  const asynchronous = runtimeListener(
    { type },
    null,
    resolve,
  );
  if (asynchronous !== true) {
    reject(new Error(`${type} did not return an asynchronous response`));
  }
});
const manualControls = () => sentMessages.filter(
  (message) => message.type === 'youtube-manual-playback-control',
);

sentMessages.length = 0;
await send('pause-youtube');
assert.equal(video.paused, true);
assert.deepEqual(manualControls(), [], 'VoiceInk automatic pause must retain bridge ownership');

await send('resume-youtube');
assert.equal(video.paused, false);
assert.deepEqual(manualControls(), [], 'VoiceInk automatic resume must not look like a manual takeover');

video.pause();
assert.deepEqual(manualControls(), [], 'page-driven playback changes are not manual takeover');
video.play();
assert.deepEqual(manualControls(), [], 'autoplay without user activation must keep bridge ownership');

userActivation.isActive = true;
video.pause();
assert.equal(manualControls().at(-1)?.action, 'pause');
video.play();
assert.equal(manualControls().at(-1)?.action, 'play');
userActivation.isActive = false;

sentMessages.length = 0;
await send('toggle-youtube');
assert.equal(manualControls().at(-1)?.action, 'pause', 'the user-triggered bridge toggle is a manual takeover');
await send('toggle-youtube');
assert.equal(manualControls().at(-1)?.action, 'play', 'both manual toggle directions relinquish ownership');

assert.match(backgroundSource, /let dictationPlaybackRelinquished = false;/);
assert.match(backgroundSource, /playbackRelinquished: dictationPlaybackRelinquished/);
assert.match(backgroundSource, /dictationPlaybackRelinquished = storedDictationState\.playbackRelinquished === true/);
assert.match(backgroundSource, /actionAt >= dictationStartedAt/);
assert.match(backgroundSource, /dictationPlaybackRelinquished = true;\s+dictationPausedTabId = null;/);
assert.match(backgroundSource, /if \(!wasIdle && dictationPlaybackRelinquished\)/);

const resumeStart = backgroundSource.indexOf('const resumeYouTubeForDictation = async (reason) => {');
const resumeEnd = backgroundSource.indexOf('\n};', resumeStart);
const resumeBody = backgroundSource.slice(resumeStart, resumeEnd);
const relinquishedGuard = resumeBody.indexOf('if (dictationPlaybackRelinquished)');
const playbackActuation = resumeBody.indexOf('resumeTabWithConfirmation');
assert.ok(relinquishedGuard >= 0 && relinquishedGuard < playbackActuation, 'manual takeover must be checked before any resume actuation');
assert.match(resumeBody, /resetDictationSession\('resume-playback-control-relinquished'\)/);
assert.match(resumeBody, /postResumeResult\(null, false, 'playback-control-relinquished'\)/);

assert.match(backgroundSource, /ts <= dictationStartedAt && dictationStartedAt - ts <= MANUAL_PAUSE_ADOPT_WINDOW_MS/);
assert.doesNotMatch(backgroundSource, /Math\.abs\(ts - dictationStartedAt\)/);

console.log('Manual YouTube playback takeover lifecycle: ok');

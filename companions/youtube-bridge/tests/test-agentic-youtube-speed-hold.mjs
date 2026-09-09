import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(
  new URL('../extension/content-script.js', import.meta.url),
  'utf8',
);

class FakeVideo extends EventTarget {
  constructor() {
    super();
    this.paused = false;
    this.ended = false;
    this.playbackRate = 1.25;
    this.currentTime = 30;
    this.duration = 120;
  }

  play() {
    this.paused = false;
    return Promise.resolve();
  }

  pause() {
    this.paused = true;
  }
}

const video = new FakeVideo();
let runtimeListener;
let cleanup;
const context = vm.createContext({
  console,
  Date,
  URL,
  Promise,
  EventTarget,
  HTMLVideoElement: FakeVideo,
  MutationObserver: class {
    observe() {}
    disconnect() {}
  },
  document: {
    title: 'Test video',
    documentElement: {},
    pictureInPictureElement: null,
    querySelector: () => video,
  },
  location: { href: 'https://www.youtube.com/watch?v=test' },
  setTimeout,
  clearTimeout,
  window: {
    setInterval: () => 1,
    clearInterval: () => {},
  },
  chrome: {
    runtime: {
      lastError: undefined,
      sendMessage: (_message, callback) => callback?.(),
      onMessage: {
        addListener: (listener) => { runtimeListener = listener; },
        removeListener: () => {},
      },
    },
  },
});
Object.defineProperty(context, '__youtubeSpotifyMediaKeyBridgeCleanup', {
  get: () => cleanup,
  set: (value) => { cleanup = value; },
  configurable: true,
});

vm.runInContext(source, context, { filename: 'content-script.js' });
assert.equal(typeof runtimeListener, 'function');
assert.equal(typeof cleanup, 'function');

const send = (type, token = 'hold-token', restorePlaybackRate) => {
  let response;
  runtimeListener({
    type,
    holdToken: token,
    playbackRate: 2,
    holdLeaseMilliseconds: 2_500,
    restorePlaybackRate,
  }, null, (value) => { response = value; });
  return response;
};

// A rate change must never seek to the hold's old position or a projected 1x position.
let playbackPosition = video.currentTime;
Object.defineProperty(video, 'currentTime', {
  get: () => playbackPosition,
  set: () => assert.fail('Speed hold must never seek the video'),
});

let response = send('begin-youtube-speed-hold');
assert.equal(response.speedHeld, true);
assert.equal(response.previousPlaybackRate, 1.25);
assert.equal(video.playbackRate, 2);

playbackPosition += 8; // Normal playback advanced during the hold.
response = send('renew-youtube-speed-hold');
assert.equal(response.speedHeld, true);
assert.equal(video.playbackRate, 2);

playbackPosition += 6;
response = send('end-youtube-speed-hold');
assert.equal(response.speedHeld, false);
assert.equal(response.previousPlaybackRate, 1.25);
assert.equal(video.playbackRate, 1.25);
assert.equal(video.currentTime, 44);

response = send('begin-youtube-speed-hold', 'locked-token');
assert.equal(response.speedHeld, true);
assert.equal(response.previousPlaybackRate, 1.25);
assert.equal(video.playbackRate, 2);

response = send('end-youtube-speed-hold', 'locked-token', 1);
assert.equal(response.speedHeld, false);
assert.equal(response.previousPlaybackRate, 1.25);
assert.equal(video.playbackRate, 1);

video.playbackRate = 1.25;
response = send('begin-youtube-speed-hold', 'invalid-restore-token', 1);
assert.equal(response.speedHeld, false);
assert.equal(response.reason, 'invalid-speed-hold-contract');
assert.equal(video.playbackRate, 1.25);

video.paused = true;
response = send('begin-youtube-speed-hold', 'paused-token');
assert.equal(response.speedHeld, false);
assert.equal(response.reason, 'no-playing-video');
assert.equal(video.playbackRate, 1.25);

video.paused = false;
response = send('begin-youtube-speed-hold', 'cleanup-token');
assert.equal(response.speedHeld, true);
assert.equal(video.playbackRate, 2);
cleanup();
assert.equal(video.playbackRate, 1.25);

console.log('Agentic Mouse YouTube speed-hold content lifecycle: ok');

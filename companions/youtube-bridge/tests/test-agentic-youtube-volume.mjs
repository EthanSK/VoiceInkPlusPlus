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
    this.playbackRate = 1;
    this.currentTime = 30;
    this.duration = 120;
    this.volume = 0.5;
    this.muted = false;
  }
}

const video = new FakeVideo();
let runtimeListener;
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

vm.runInContext(source, context, { filename: 'content-script.js' });
assert.equal(typeof runtimeListener, 'function');

const adjustVolume = (volumeDelta) => {
  let response;
  runtimeListener(
    { type: 'adjust-youtube-volume', volumeDelta },
    null,
    (value) => { response = value; },
  );
  return response;
};

assert.equal(adjustVolume(0.05).volumeAdjusted, true);
assert.equal(video.volume, 0.55);
assert.equal(video.paused, false, 'volume must not change playback state');

assert.equal(adjustVolume(-0.05).volumeAdjusted, true);
assert.equal(video.volume, 0.5);

video.volume = 0.98;
assert.equal(adjustVolume(0.05).volumeAdjusted, true);
assert.equal(video.volume, 1, 'volume up clamps at one');

video.volume = 0.02;
assert.equal(adjustVolume(-0.05).volumeAdjusted, true);
assert.equal(video.volume, 0, 'volume down clamps at zero');

video.volume = 0.5;
video.muted = true;
assert.equal(adjustVolume(0.05).volumeAdjusted, true);
assert.equal(video.volume, 0.55);
assert.equal(video.muted, false, 'volume up deliberately unmutes the playing video');

video.paused = true;
const pausedResponse = adjustVolume(0.05);
assert.equal(pausedResponse.volumeAdjusted, false);
assert.equal(pausedResponse.reason, 'no-playing-video');
assert.equal(video.volume, 0.55, 'paused videos must not steal the volume command');

video.paused = false;
for (const invalid of [-0.1, 0, 0.1, undefined]) {
  video.volume = 0.5;
  const response = adjustVolume(invalid);
  assert.equal(response.volumeAdjusted, false);
  assert.equal(response.reason, 'invalid-volume-contract');
  assert.equal(video.volume, 0.5);
}

console.log('Agentic Mouse YouTube five-percent volume lifecycle: ok');

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
    this.paused = true;
    this.ended = false;
    this.playbackRate = 1;
    this.currentTime = 30;
    this.duration = 120;
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

const seek = (seekSeconds) => {
  let response;
  runtimeListener(
    { type: 'seek-youtube', seekSeconds },
    null,
    (value) => { response = value; },
  );
  return response;
};

assert.equal(seek(5).sought, true);
assert.equal(video.currentTime, 35);
assert.equal(video.paused, true, 'scrubbing must preserve playback state');

assert.equal(seek(-5).sought, true);
assert.equal(video.currentTime, 30);

video.currentTime = 2;
assert.equal(seek(-5).sought, true);
assert.equal(video.currentTime, 0, 'backward scrubbing clamps at zero');

video.currentTime = 118;
assert.equal(seek(5).sought, true);
assert.equal(video.currentTime, 120, 'forward scrubbing clamps at duration');

for (const invalid of [-10, 0, 10, undefined]) {
  video.currentTime = 30;
  const response = seek(invalid);
  assert.equal(response.sought, false);
  assert.equal(response.reason, 'invalid-seek-contract');
  assert.equal(video.currentTime, 30);
}

console.log('Agentic Mouse YouTube five-second scrub lifecycle: ok');

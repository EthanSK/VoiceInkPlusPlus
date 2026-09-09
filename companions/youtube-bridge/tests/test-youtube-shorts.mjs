import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const source = fs.readFileSync(new URL('../extension/content-script.js', import.meta.url), 'utf8');

class Video extends EventTarget {
  paused = false;
  ended = false;
  playbackRate = 1.25;
  currentTime = 30;
  duration = 109.201;
  volume = 0.5;
  muted = false;
  playFailures = 0;
  playCalls = 0;
  pauseCalls = 0;
  play() {
    this.playCalls++;
    if (this.playFailures-- > 0) return Promise.reject(new Error('not ready'));
    this.paused = false;
    this.dispatchEvent(new Event('play'));
    return Promise.resolve();
  }
  pause() {
    this.pauseCalls++;
    this.paused = true;
    this.dispatchEvent(new Event('pause'));
  }
  closest() { return { querySelector: () => null }; }
}

function setup() {
  const watch = new Video();
  watch.paused = true;
  watch.currentTime = 0;
  watch.duration = NaN;
  const short = new Video();
  const messages = [];
  const timers = new Map();
  const state = { activeShort: short, firstVideo: watch, watchVisible: false };
  const location = { href: 'https://www.youtube.com/shorts/Th8FU-Bw6Gc' };
  let listener;
  let mutation;
  let nextTimer = 0;
  let hiddenButtonClicks = 0;
  class Element { click() { hiddenButtonClicks++; } }
  const document = {
    title: 'Shorts fixture', documentElement: {}, pictureInPictureElement: null,
    querySelector(selector) {
      if (selector === 'ytd-shorts:not([hidden]) #shorts-player video.html5-main-video') return state.activeShort;
      if (selector === 'ytd-watch-flexy:not([hidden]) #movie_player video.html5-main-video') return state.watchVisible ? watch : null;
      if (selector === '.ytp-play-button') return new Element();
      return state.firstVideo;
    },
  };
  const context = vm.createContext({
    URL, Date, Promise, EventTarget, HTMLVideoElement: Video, HTMLElement: Element,
    location, document, navigator: { userActivation: { isActive: false } },
    MutationObserver: class {
      constructor(callback) { mutation = callback; }
      observe() {}
      disconnect() {}
    },
    setTimeout: (callback, delay) => { timers.set(++nextTimer, { callback, delay }); return nextTimer; },
    clearTimeout: id => timers.delete(id),
    window: { setInterval: () => 1, clearInterval() {}, setTimeout: callback => setTimeout(callback, 0) },
    chrome: { runtime: {
      sendMessage: (message, callback) => { messages.push(message); callback?.(); },
      onMessage: { addListener: callback => { listener = callback; }, removeListener() {} },
    } },
  });
  vm.runInContext(source, context);
  return {
    watch, short, state, location, document, messages, context,
    refresh: () => mutation(),
    hiddenButtonClicks: () => hiddenButtonClicks,
    expire: () => { for (const timer of [...timers.values()]) timer.callback(); },
    send: (type, extra = {}) => new Promise(resolve => listener({ type, ...extra }, {}, resolve)),
    cleanup: () => context.__youtubeSpotifyMediaKeyBridgeCleanup(),
  };
}

const hold = { holdToken: 'shorts-hold', playbackRate: 2, holdLeaseMilliseconds: 2500 };

test('Shorts rewind and scrub use the visible clip behind a retained empty watch player', async () => {
  const h = setup();
  assert.equal((await h.send('seek-youtube', { seekSeconds: -5 })).sought, true);
  assert.equal(h.short.currentTime, 25);
  await h.send('seek-youtube', { seekSeconds: 5 });
  assert.equal(h.short.currentTime, 30);
  h.short.currentTime = 2;
  await h.send('seek-youtube', { seekSeconds: -5 });
  assert.equal(h.short.currentTime, 0);
  h.short.currentTime = 108;
  await h.send('seek-youtube', { seekSeconds: 5 });
  assert.equal(h.short.currentTime, h.short.duration);
  assert.equal(h.short.paused, false);
  assert.equal(h.watch.currentTime, 0);
  assert.equal(h.messages.find(m => m.type === 'youtube-state').playing, true);
  h.cleanup();
});

test('Shorts volume changes five points, preserves playback and supports unmute', async () => {
  const h = setup();
  h.short.muted = true;
  assert.equal((await h.send('adjust-youtube-volume', { volumeDelta: 0.05 })).volumeAdjusted, true);
  assert.equal(h.short.volume, 0.55);
  assert.equal(h.short.muted, false);
  await h.send('adjust-youtube-volume', { volumeDelta: -0.05 });
  assert.equal(h.short.volume, 0.5);
  assert.equal(h.watch.volume, 0.5);
  assert.equal(h.short.paused, false);
  h.cleanup();
});

test('Shorts momentary speed, renewal, sticky reset and expiry preserve their contracts', async () => {
  const h = setup();
  assert.equal((await h.send('begin-youtube-speed-hold', hold)).speedHeld, true);
  assert.equal(h.short.playbackRate, 2);
  await h.send('renew-youtube-speed-hold', hold);
  await h.send('end-youtube-speed-hold', hold);
  assert.equal(h.short.playbackRate, 1.25);
  await h.send('begin-youtube-speed-hold', hold);
  await h.send('end-youtube-speed-hold', { ...hold, restorePlaybackRate: 1 });
  assert.equal(h.short.playbackRate, 1);
  await h.send('begin-youtube-speed-hold', hold);
  h.expire();
  assert.equal(h.short.playbackRate, 1);
  assert.equal(h.watch.playbackRate, 1.25);
  h.cleanup();
});

test('Shorts pause, resume and toggle never actuate the retained watch player', async () => {
  const h = setup();
  assert.equal((await h.send('pause-youtube')).paused, true);
  assert.equal(h.short.paused, true);
  assert.equal((await h.send('resume-youtube')).resumed, true);
  assert.equal(h.short.paused, false);
  await h.send('toggle-youtube');
  assert.equal(h.short.paused, true);
  assert.equal(h.watch.playCalls + h.watch.pauseCalls, 0);
  h.cleanup();
});

test('Shorts resume recovery cannot click a hidden watch-player button', async () => {
  const h = setup();
  h.short.paused = true;
  h.short.playFailures = 1;
  assert.equal((await h.send('resume-youtube')).resumed, true);
  assert.equal(h.hiddenButtonClicks(), 0);
  assert.equal(h.watch.playCalls, 0);
  h.cleanup();
});

test('A loading Short has no fallback to the hidden watch player', async () => {
  const h = setup();
  h.state.activeShort = null;
  assert.equal((await h.send('seek-youtube', { seekSeconds: 5 })).sought, false);
  assert.equal(h.watch.currentTime, 0);
  h.cleanup();
});

test('Changing Shorts releases speed and detaches the previous element listeners', async () => {
  const h = setup();
  await h.send('begin-youtube-speed-hold', hold);
  const next = new Video();
  h.state.activeShort = next;
  h.location.href = 'https://www.youtube.com/shorts/next';
  h.refresh();
  assert.equal(h.short.playbackRate, 1.25);
  assert.equal((await h.send('renew-youtube-speed-hold', hold)).speedHeld, false);
  assert.equal(next.playbackRate, 1.25);
  h.context.navigator.userActivation.isActive = true;
  h.messages.length = 0;
  h.short.pause();
  assert.equal(h.messages.length, 0, 'events from the old element cannot impersonate current playback');
  next.pause();
  assert.equal(h.messages.filter(m => m.type === 'youtube-manual-playback-control').length, 1);
  h.cleanup();
});

test('A reused Shorts element cannot renew the previous clip speed lease', async () => {
  const h = setup();
  await h.send('begin-youtube-speed-hold', hold);
  h.location.href = 'https://www.youtube.com/shorts/reused';
  assert.equal((await h.send('renew-youtube-speed-hold', hold)).speedHeld, false);
  assert.equal(h.short.playbackRate, 1.25);
  h.cleanup();
});

test('Picture-in-Picture stays preferred and its speed lease survives page navigation', async () => {
  const h = setup();
  const pip = new Video();
  h.document.pictureInPictureElement = pip;
  await h.send('seek-youtube', { seekSeconds: -5 });
  assert.equal(pip.currentTime, 25);
  assert.equal(h.short.currentTime, 30);
  await h.send('begin-youtube-speed-hold', hold);
  h.location.href = 'https://www.youtube.com/shorts/other';
  assert.equal((await h.send('renew-youtube-speed-hold', hold)).speedHeld, true);
  await h.send('end-youtube-speed-hold', hold);
  assert.equal(pip.playbackRate, 1.25);
  h.cleanup();
});

test('Returning to a watch page targets its player even if Shorts comes first', async () => {
  const h = setup();
  h.location.href = 'https://www.youtube.com/watch?v=regular';
  h.state.firstVideo = h.short;
  h.state.watchVisible = true;
  h.watch.duration = 100;
  await h.send('seek-youtube', { seekSeconds: 5 });
  assert.equal(h.watch.currentTime, 5);
  assert.equal(h.short.currentTime, 30);
  h.cleanup();
});

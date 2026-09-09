import assert from 'node:assert/strict';
import fs from 'node:fs';

const source = fs.readFileSync(
  new URL('../extension/background.js', import.meta.url),
  'utf8',
);

const handlerStart = source.indexOf("void enqueueDictationOp('watchdog', async () => {");
assert.notEqual(handlerStart, -1, 'missing dictation watchdog handler');

const handlerEnd = source.indexOf('\n  });\n});', handlerStart);
assert.notEqual(handlerEnd, -1, 'unterminated dictation watchdog handler');

const handler = source.slice(handlerStart, handlerEnd);
assert.match(handler, /resetDictationSession\('watchdog-stale-session-cleanup'\)/);
assert.match(handler, /clearDictationWatchdog\(\)/);
assert.doesNotMatch(handler, /resumeTabWithConfirmation/);
assert.doesNotMatch(handler, /resume-youtube/);
assert.doesNotMatch(handler, /\.play\s*\(/);

for (const startupMarker of [
  'chrome.runtime.onInstalled.addListener(() => {',
  'chrome.runtime.onStartup.addListener(() => {',
]) {
  const start = source.indexOf(startupMarker);
  assert.notEqual(start, -1, `missing ${startupMarker}`);
  const end = source.indexOf('\n});', start);
  assert.notEqual(end, -1, `unterminated ${startupMarker}`);
  const handlerSource = source.slice(start, end);
  assert.doesNotMatch(handlerSource, /resume-youtube/);
  assert.doesNotMatch(handlerSource, /resumeTabWithConfirmation/);
}

console.log('Watchdog and extension startup preserve YouTube playback state.');

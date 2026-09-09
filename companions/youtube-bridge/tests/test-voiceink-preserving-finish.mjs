import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (relativePath) => fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');

const shared = read('shared/YoutubeSpotifyMediaKeyShared.swift');
const menu = read('menu-bar/main.swift');
const host = read('native-host/YoutubeSpotifyMediaKeyNativeHost.swift');
const background = read('extension/background.js');

const notificationName = 'com.ethansk.voiceink.recordingStoppedPreservingPlayback';
const bridgeCommand = 'finish-dictation-preserving-playback';

assert.match(shared, new RegExp(notificationName.replaceAll('.', '\\.')));
assert.match(menu, /name: VoiceInkRecordingNotification\.stoppedPreservingPlayback/);
assert.match(menu, /handleVoiceInkRecordingStoppedPreservingPlayback/);
assert.match(menu, new RegExp(`BridgeMessage\\(type: "${bridgeCommand}"\\)`));
assert.match(menu, /pendingVoiceInkPreservePlayback/);

assert.match(host, new RegExp(`case "${bridgeCommand}":`));
assert.match(host, /app→Chrome finish-dictation-preserving-playback/);

assert.match(background, new RegExp(`case '${bridgeCommand}':`));
assert.match(background, /finishDictationPreservingPlayback\(finishReason\)/);

const functionStart = background.indexOf('const finishDictationPreservingPlayback = async (reason) => {');
assert.notEqual(functionStart, -1, 'missing preserving-finish implementation');
const functionEnd = background.indexOf('\n};', functionStart);
assert.notEqual(functionEnd, -1, 'unterminated preserving-finish implementation');
const functionBody = background.slice(functionStart, functionEnd + 3);

assert.match(functionBody, /dictationDepth = Math\.max\(0, dictationDepth - 1\)/);
assert.match(functionBody, /resetDictationSession\('finish-preserving-playback'\)/);
assert.match(functionBody, /clearDictationWatchdog\(\)/);
assert.match(functionBody, /playbackCommand=none/);
assert.doesNotMatch(functionBody, /sendDirectional/);
assert.doesNotMatch(functionBody, /resumeTabWithConfirmation/);
assert.doesNotMatch(functionBody, /pauseYouTubeForDictation/);
assert.doesNotMatch(functionBody, /resumeYouTubeForDictation/);

console.log('VoiceInk playback-preserving finish bridge contract passed.');

# VoiceInk YouTube Bridge

Personal macOS + Chrome helper for pausing a playing YouTube tab while VoiceInk++ is recording and resuming only that same tab when recording stops.

## How It Works

- Hardware media-key routing is intentionally disabled. Do not re-enable the macOS media-key event tap for the VoiceInk++ flow.
- The menu bar app listens for VoiceInk++ recording lifecycle notifications and relays directional YouTube commands through the native bridge.
- The Chrome extension watches YouTube tabs and reports video play/pause state through a thin native bridge.
- The same extension records each Chrome window's tab-activation order for Agentic Mouse tab-history navigation.
- Agentic Mouse can also ask the extension to open one fixed website immediately beside Chrome's active tab.

## VoiceInk++ dictation auto-pause

The menu bar app also pauses a playing YouTube tab while you dictate with VoiceInk++ and resumes it when you finish:

- Compatible VoiceInk++ versions (bundle `com.ethansk.VoiceInkPlusPlus`) broadcasts `com.ethansk.voiceink.recordingStarted`, `com.ethansk.voiceink.recordingStopped`, or the triple-click-specific `com.ethansk.voiceink.recordingStoppedPreservingPlayback` over macOS `DistributedNotificationCenter` from its recorder lifecycle.
- On `recordingStarted`, the menu bar app sends an untargeted directional `pause-youtube`; the extension prefers PiP, then the active YouTube tab in Chrome's last-focused window, then audible/active/playback-recency fallbacks, and remembers the tab it actually paused.
- On `recordingStopped`, the extension sends `resume-youtube` **only** to the tab it paused — so it never starts a video that wasn't already playing. An immediate new start supersedes that resume and keeps ownership of the same tab.
- If you manually press Play or Pause after recording starts, that user action relinquishes the saved playback target for the whole recording session. Later stop/cancel edges still balance bridge state but never play or pause YouTube; page autoplay, seeking, volume, speed, timeouts, and bridge reloads do not count as manual takeover.
- On `recordingStoppedPreservingPlayback`, it balances/clears the same dictation ownership without sending any play or pause command. This supports VoiceInk++ versions that emit the preserving-playback notification. The current public app source does not emit that event yet; installing this companion alone does not add the triple-click gesture.
- If the extension's four-minute stale-session watchdog fires, it clears only its saved dictation ownership. Timeout, extension startup, helper restart, and content-script reinjection never call `play()`; an explicit matching `recordingStopped` event is required to resume a video paused for dictation.
- This is complementary to VoiceInk++'s own media pause (Spotify / Apple Music / MediaRemote): those apps stay on the VoiceInk side; YouTube tabs in Chrome — which MediaRemote can't reliably pause — are covered here.

The notification-name strings are the cross-app contract and live in both `shared/YoutubeSpotifyMediaKeyShared.swift` (`VoiceInkRecordingNotification`) and the VoiceInk++ repo's `RecordingActivityNotifier.swift`; keep them in sync.

## Agentic Mouse YouTube scrub

Agentic Mouse can scrub the watched YouTube video without focusing Chrome by posting the no-payload
DistributedNotificationCenter names `com.ethansk.agenticmouse.youtube.seekBackwardFiveSeconds` and
`com.ethansk.agenticmouse.youtube.seekForwardFiveSeconds`. The menu-bar bridge relays the strict
`seek-youtube` / `seekSeconds: -5|5` native message; the extension
uses its existing PiP → last-focused active → audible → active → playback-recency target ordering and
sets the selected video’s `currentTime` backward or forward five seconds, clamped to zero and finite
duration. Each ratchet is a one-shot
command: if the bridge is down it is dropped, never replayed later.

## Agentic Mouse YouTube volume

Agentic Mouse can change only the currently playing YouTube video's volume without focusing Chrome by
posting `com.ethansk.agenticmouse.youtube.volumeDecreaseFivePercent` or
`com.ethansk.agenticmouse.youtube.volumeIncreaseFivePercent`. The menu-bar bridge converts those fixed
notifications into the strict `adjust-youtube-volume` native message with `volumeDelta: -0.05|0.05`.
The extension reuses its existing target ordering but accepts the command only in a content script whose
video is genuinely playing, so a paused active browser tab cannot steal volume from the playing video.
Each one-shot command clamps at 0–100%, volume-up unmutes, and neither direction changes playback state,
focuses Chrome, or queues work while the bridge is unavailable.

## Agentic Mouse hold or lock at 2× speed

Chrome mode can hold the extension-selected, currently playing YouTube video at 2× without focusing
Chrome. Agentic Mouse posts opaque-token begin/renew/end notifications. The extension reuses the same
PiP → last-focused active → audible → active → playback-recency target ordering, saves that exact
video's prior playback rate, and restores it on ordinary physical release. A same-mouse double-click
keeps that same token-bound lease renewing at 2× after release; the next same-mouse double-click
explicitly sets the bound video to 1×. A 2.5-second content-script lease still restores the saved
prior rate after a lost release, mode exit, lock, helper disconnect, extension reload, or app teardown.
It never changes play/pause state, and only the deliberate sticky unlock is allowed to request 1×.

## Agentic Mouse Chrome tab history

Chrome mode can move backward and forward through the tabs actually activated in Chrome's last-focused
normal window. The extension records a bounded 100-entry activation timeline per window, persists it
across Manifest V3 service-worker restarts, and treats a manual tab selection after Back as a new branch
that discards the old forward history. Closed or moved tabs are removed or skipped. Navigation activates
only a tab in that same Chrome window; it never focuses Chrome or jumps to another Chrome window.

Agentic Mouse posts one of the fixed no-payload notifications
`com.ethansk.agenticmouse.chrome.tabHistoryBack` or
`com.ethansk.agenticmouse.chrome.tabHistoryForward`. The helper and native host relay only exact
`back` / `forward` values to the extension.

## Agentic Mouse Chrome websites

Chrome mode's website submenu sends one allow-listed identifier for YouTube, X, Facebook, Ethan's GitHub,
LinkedIn, Gemini, or Grok. The extension is the single source of truth for those seven URLs and rejects
arbitrary values. It finds the active tab in Chrome's last-focused normal window and creates the selected
site as the active tab immediately to its right without focusing another Chrome window.

## Requirements and standalone source

This directory includes the Chrome extension, Swift native messaging host, menu bar app,
icon, build/install/uninstall scripts, and regression tests. It needs no private repository,
submodule, package registry, or credentials. It can also be copied out of VoiceInk++ and built
on its own. VoiceInk++ and Agentic Mouse are separate apps that send the documented notifications.

- macOS 13 or later, Google Chrome, and Apple Command Line Tools (`xcode-select --install`).
- Python 3 for the installer; Node.js 22 or later for tests.
- Normal builds use the included icon and ad-hoc signing; no Apple Developer account or Pillow is needed.
- Only regenerating artwork with `scripts/generate-icon.sh` requires Pillow.
- The main VoiceInk++ app has its own Xcode and macOS requirements in [BUILDING.md](../../BUILDING.md).

See [AGENT_SETUP.md](AGENT_SETUP.md) for the agent setup prompt and verification checklist.

## Build and test without installation

```sh
./scripts/test.sh
./scripts/build.sh
```

Building writes only to this directory's `dist/`; it does not launch anything or change Chrome.
To use a signing certificate you own, set `YOUTUBE_SPOTIFY_MEDIA_KEY_CODESIGN_IDENTITY`.
The installer updates this helper's existing installation and restarts it, so finish any active
dictation first. Keep this folder in its chosen location after installing: Chrome's native host
registration and unpacked extension refer to its `dist/` paths. If you move it, reinstall and
load the extension from its new location.

## Install

From the VoiceInk++ repository root:

```sh
cd companions/youtube-bridge
./scripts/install.sh
```

Then:

1. Open `chrome://extensions`.
2. Enable Developer mode.
3. Click Load unpacked.
4. Pick the `dist/extension` folder inside this companion directory.
5. Reload any YouTube tabs that were already open.

> After changing extension JS and rebuilding (`./scripts/build.sh` refreshes `dist/extension`), go to `chrome://extensions`, click **Reload** on this extension, then reload any open YouTube tabs so the new content script is injected. A content-script-only update can also load through the existing command-time reinjection path; verify a changed result in the live page before treating that path as installed.

YouTube playback controls support both normal watch pages and Shorts. On Shorts,
the content script selects the active Shorts player instead of a retained hidden
watch player. Rewind, five-second wheel scrubbing, five-point volume changes,
temporary 2× speed, and sticky-speed reset use the same selected video. A speed
hold ends when its clip changes, including when Shorts reuses the video element;
Picture-in-Picture retains priority. Returning to a watch page selects its player.

The install script also copies the menu bar app to `~/Applications/YouTube Spotify Media Key.app`, launches it, and registers a LaunchAgent so it starts at login.

The extension ID should be:

```text
kjcofljkanbdomkahdicnibojcoagmjl
```

## macOS Permissions

The VoiceInk++ YouTube auto-pause path does not require macOS Accessibility, Input Monitoring, or Spotify Automation permissions.

If macOS asks for Accessibility for this helper, that is a bug or an old installed build. Rebuild/install from this repo and reload the unpacked Chrome extension.

## Debug

Check Spotify state:

```sh
./dist/native-host/youtube-spotify-media-key-host --spotify-state
```

Check that the installed helper will not request Accessibility:

```sh
~/Applications/YouTube\ Spotify\ Media\ Key.app/Contents/MacOS/youtube-spotify-media-key-app --request-accessibility
```

Rebuild after changes:

```sh
./scripts/build.sh
```

Uninstall the Chrome native messaging manifest:

```sh
./scripts/uninstall.sh
```

## Source and license

Packaged by Ethan SK from the existing YouTube bridge implementation, including its tested watch-page and Shorts support. The source is distributed under the repository’s GPL-3.0 license (also included in this directory). No browser profile, private settings, or installed binaries are included.

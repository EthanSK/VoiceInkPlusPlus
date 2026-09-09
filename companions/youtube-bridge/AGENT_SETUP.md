# Set up VoiceInk++ and the YouTube companion

Paste this into your local coding agent:

> Read the VoiceInk++ README, BUILDING.md and companions/youtube-bridge/README.md in https://github.com/EthanSK/VoiceInkPlusPlus. Inspect my existing installation and preserve local settings. Build VoiceInk++ and its included YouTube companion using their documented requirements. Run the companion tests, then install it when no dictation is active. Help me load its unpacked extension in Chrome and verify automatic YouTube pause/resume using a disposable video. Do not copy Ethan's paths or private credentials. Report build, install, extension connection and actual playback verification separately.

## Agent procedure

1. Read the repository instructions. On Ethan's machines, native builds belong on his Mac Mini; use a task-owned directory. On another user's Mac, use their authorized build machine.
2. Inspect existing VoiceInk++, companion and unpacked-extension paths. Preserve unrelated work and browser tabs. Do not install or restart during an active recording.
3. Build the main app from the repo root using BUILDING.md. Use your own transcription provider credentials or a supported local model; no private proxy is bundled.
4. Run `./scripts/test.sh` and `./scripts/build.sh` from this directory. Confirm the native host and menu app signatures with `codesign --verify --strict`, and confirm `dist/extension/manifest.json` exists.
5. Run `./scripts/install.sh` on the target Mac when safe. It rebuilds locally, registers the host for Google Chrome, copies the menu app to `~/Applications`, and creates its login LaunchAgent. Keep this directory in a stable location.
6. In `chrome://extensions`, enable Developer mode and load this directory's `dist/extension`. The expected extension ID is `kjcofljkanbdomkahdicnibojcoagmjl`. Reload only the disposable YouTube test tabs to inject the content script.
7. Open the extension's status page. Confirm the bridge connection and watched test tab. Do not infer connection from a successful build alone.
8. Play the test video, start real VoiceInk++ dictation, and verify it pauses. Finish dictation and verify that same video resumes. Repeat with an initially paused video: it must stay paused. Manually take over playback during dictation: the final stop must preserve your choice.
9. If Agentic Mouse is installed, check its documented seek, volume, speed and tab-history controls separately. Its hardware configuration is not bundled here. Optional preserving-playback notifications require a compatible VoiceInk++ version; do not claim the public app has an unpublished gesture.
10. Record which runtime and physical checks actually passed. Mock tests do not prove installed playback behavior. Use `scripts/uninstall.sh` only when removal is requested; Chrome's unpacked entry is removed separately in its extension manager.

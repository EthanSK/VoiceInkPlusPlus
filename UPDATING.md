# Updating this fork (EthanSK/VoiceInk) against upstream

This is Ethan's personal GPL-3.0 fork of [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk).
VoiceInk++ now deliberately diverges in destination routing, non-activating delivery, recorder UI,
identity, and custom-model vocabulary handling. Treat upstream as a source of individual features,
not as a branch to merge wholesale.

## Our patches (preserve these through every upstream port)

The fork's important behavioral patches are:

- **#785 — Mode follows the current app (the load-bearing fix).** Adds an
  `NSWorkspace.didActivateApplicationNotification` observer in `ActiveWindowService.start()` so the
  active Mode re-resolves whenever the frontmost app changes — *including during recording*. Upstream
  only resolves the Mode at record-start, which breaks the common "start dictating, then click the
  target field" workflow (it pastes into the right app but with the wrong app's auto-send). With the
  observer, at paste/delivery time the Mode matches the app you're actually in.
- **#784 — neutral nil-fallback.** When an app has no enabled matching Mode and there's no
  enabled+default Mode, `setActiveConfiguration(nil)` (neutral paste / no auto-send) instead of
  silently retaining the previous app's Mode.
- **ChatGPT floating-window fix — resolve the KEYBOARD-focused app via Accessibility.** Adds
  `accessibilityFocusedApplication()` to `ActiveWindowService` and uses it (with a
  `frontmostApplication` fallback) inside `beginApplyingConfiguration`. The ChatGPT desktop app's
  floating companion/quick-access window is a `.nonactivatingPanel`: it takes keyboard focus WITHOUT
  changing `NSWorkspace.frontmostApplication` and WITHOUT firing `didActivateApplicationNotification`,
  so neither the record-start read nor the #785 observer ever saw ChatGPT → its per-app Mode (incl.
  auto-Enter) never activated and the menu-bar Mode indicator stayed wrong. The AX system-wide
  focused element DOES follow into the panel, so we read its owning pid → bundle id. Safe/additive:
  for ordinary windows the AX-focused app == frontmost app. Falls back when AX is untrusted, exposes
  no focused element, or the focus is VoiceInk's own (also non-activating) recorder panel.
- **Per-recording destination control — base Primary plus two exact Next routes.** The normal
  recording shortcut always uses base VoiceInk current-input delivery: whichever input and Mode own
  system keyboard focus when the final result is delivered decide paste and optional Return. Primary
  stores no exact destination and can never enter an app-specific resolver. The macOS Next Track
  media key instead stops into the exact Accessibility input captured at recording start. When
  Electron/Chromium exposes only `AXWebArea` during the shortcut, that recording-start route may use
  its bounded application fallback. Each `RecordingSession` owns its immutable start candidate and
  resolved paste target, preventing concurrent background transcriptions from mixing destinations.
  While the newest normal-stop transcription is still running and before destination-dependent
  post-processing begins, Next Track can replace its target with the input focused at that moment;
  the pipeline freezes exact input plus complete Mode before formatting or enhancement. Delivery
  re-resolves and verifies the exact element without activating a background target, and copies to
  the clipboard rather than pasting into an unintended field if verification fails. This post-stop
  action is the distinct **second chance** and is never a toggle. While any recorder/transcription bar
  is visible, an ineligible Next press is consumed as a no-op; media pass-through resumes only after
  the bar hides. The historical `VIPPExactInputDeliveryEnabled` preference is no longer read.
  See the canonical
  [Mouse terminology](TERMINOLOGY.md) and [Recording Destination Controls](RECORDING_DESTINATIONS.md)
  for user examples, setup, failure behavior, logs, and the implementation map.
- **Soniox realtime owned-range input.** With `VIPPRealtimeInputStreamingEnabled` on, a Soniox V5
  realtime recording mirrors cumulative hypotheses into only the exact UTF-16 selected-text range
  inserted in the system-focused input. Moving focus seeds the complete draft into the new input;
  same-app cleanup is allowed only through a revalidated direct Accessibility session, while
  cross-app residue is deliberately retained. Final Primary delivery reconciles the current input
  without becoming a saved route; either Next route reconciles its existing exact target and Mode.
  Telegram and rich inputs without safe selected-text mutation skip live writing. Any indeterminate
  mutation blocks further writes for that app/recording and forbids duplicate final paste.
- **Exact non-activating delivery.** When a session owns an exact input in a background app,
  VoiceInk++ uniquely re-resolves its window/editor, opens one internal activation-state session when
  needed, and verifies immediate keyboard-focus safety plus exact insertion. The same route handles a
  different input in the already-frontmost target app through direct Accessibility only, so it cannot
  steal intra-app focus. Telegram alone has a version/layout-pinned retained-element path, but only
  while readable chat anchors or the privacy-bounded avatar/title-region digest revalidate immediately
  before insertion and its one accepted HID Return sequence; hidden, mismatched, or unaudited context
  fails closed. Chat verification requires a composer reset. Apple Terminal/iTerm capture stable
  window-ID + TTY/session-ID pairs and send transcript text
  plus Return to that exact pair in one native operation, verified through native contents and a prompt
  transition; Apple Terminal paste-only fails closed while iTerm may use `newline false`; mutable titles are never identities;
  Ghostty, Warp, VS Code, Cursor, Chrome, Notion, and generic editors have no safe generic background
  Return. Only a proven unchanged OpenAI composer that still owns system keyboard focus may retry one
  ordinary-HID Return. Semantic AX Send requires an explicit Send label; an unlabelled OpenAI square
  can be Stop while an agent runs and is never pressed based on wrapper/geometry alone. Background
  Command-V, process-targeted Return, and activating a
  background target as a fallback remain forbidden. See `BACKGROUND_DELIVERY_TEST_MATRIX.md`.

The active-window service's `start()` is wired once at app launch in `VoiceInk.swift` (right after
`ActiveWindowService.shared`).

## Build (MUST be on the Mac Mini — never the MBP)

`xcodebuild` fires codesign dialogs on the MBP; the Mini is the dedicated build box. VoiceInk is a
native Swift/SwiftUI app, **not** Electron, so changes require a recompile (you can't hot-patch the
installed `.app`).

```sh
# on the Mac Mini:
cd ~/Projects/VoiceInk-build        # the Mini's clone of this fork
make local                          # builds whisper.cpp (cached after first time) + ad-hoc-signed xcodebuild
# output: ~/Downloads/VoiceInkPlusPlus.app  (quarantine already stripped by the Makefile)
```

`make local` injects the `LOCAL_BUILD` compile flag → `LicenseViewModel` is hard-coded to `.licensed`,
so a local build is permanently Pro with **no** trial/keychain/Polar gate. No Apple Developer cert
needed (ad-hoc `CODE_SIGN_IDENTITY = -`). Mic / Accessibility / Screen-Recording are normal TCC grants
on first launch.

The built bundle is **`VoiceInkPlusPlus.app`** (output: `~/Downloads/VoiceInkPlusPlus.app`) — the
`PRODUCT_NAME` is the build-path-safe `VoiceInkPlusPlus`; the user-visible name is **VoiceInk++** via
`CFBundleDisplayName`.

### Install completed fixes into the running app (mandatory)

A VoiceInk++ code fix is not complete when the source builds: install that exact build into
`/Applications/VoiceInkPlusPlus.app` and relaunch it so Ethan is testing the corrected binary. Never
replace or stop `/Applications/VoiceInk.app`, which is the separate official app.

Before every native release, increment `CURRENT_PROJECT_VERSION` in both main-app build configurations.
The recorder bar renders `v<MARKETING_VERSION>` on its first row and
`.<CURRENT_PROJECT_VERSION>` on its second row immediately left of Stop, so each installed binary must
have a unique build number. Do not reuse a build number after changing native source, and do not call
source-only work released or installed.

Before every update that quits or replaces the running VoiceInk++ app, warn Ethan and give him a real
five-second recovery window:

```sh
osascript -e 'display notification "VoiceInk++ will restart in 5 seconds" with title "VoiceInk++ update"'
sleep 5
```

Only after that delay: quit VoiceInk++, preserve a timestamped rollback bundle, replace the app,
relaunch it, and verify the new PID plus the strict/deep code signature and stable designated
requirement. Do not claim a live fix while an older PID/build remains running.

## Standalone-fork identity — VoiceInk++ (separate app from the official VoiceInk)

This fork is rebranded to **VoiceInk++** with its **own** bundle id so it installs and permissions
**alongside** the official VoiceInk without colliding on TCC permissions, UserDefaults/prefs, keychain,
or Application Support storage.

- **Bundle id:** `com.ethansk.VoiceInkPlusPlus` (main app). Tests use
  `com.ethansk.VoiceInkPlusPlus.Tests` / `.UITests`. (Was `com.prakashjoshipax.VoiceInk` upstream.)
- **Product name / file:** `VoiceInkPlusPlus` → builds `VoiceInkPlusPlus.app`.
- **Display name (CFBundleDisplayName):** `VoiceInk++` (what the user sees in the menu bar, Dock,
  About panel, window title).
- **Self-storage moved to the new id:** Application Support folder
  (`~/Library/Application Support/com.ethansk.VoiceInkPlusPlus/`), the `Recordings` subfolder, and the
  keychain service name (`com.ethansk.VoiceInkPlusPlus`) all use the new id, so VoiceInk++ keeps its
  own data/models/recordings/secrets separate from the official app.
- **Prefs plist:** macOS auto-derives it from the bundle id, so VoiceInk++'s prefs live at
  `~/Library/Preferences/com.ethansk.VoiceInkPlusPlus.plist` — no longer shared with the official app.
- **Deliberately LEFT as the upstream id (don't change without provisioning):** the iCloud CloudKit
  container `iCloud.com.prakashjoshipax.VoiceInk` (entitlements + `VoiceInk.swift`). It must match a
  provisioned container in the Apple Developer account; Ethan's `make local` path forces CloudKit to
  `.none` (and the local entitlements omit iCloud), so the old container id is inert for his builds.
  The lowercase OSLog subsystem / dispatch-queue labels (`com.prakashjoshipax.voiceink`) are also left
  as-is — they're cosmetic logging namespaces, not TCC/storage identity.

### Mini resign-local.sh / Designated Requirement (DR) impact

Because the bundle id changed, the Mini's resign / install pipeline (`resign-local.sh` and any DR
pinning) must now expect the **new** identity. The Designated Requirement becomes:

```
identifier "com.ethansk.VoiceInkPlusPlus" and certificate leaf = H"..."
```

(was `identifier "com.prakashjoshipax.VoiceInk" and ...`). Update any DR/codesign verification on the
Mini to match `com.ethansk.VoiceInkPlusPlus`, and point any app-path references at
`VoiceInkPlusPlus.app` (display name `VoiceInk++`). The first launch of the rebranded app will prompt
fresh TCC grants (Mic / Accessibility / Screen Recording) because it's a brand-new identity to macOS —
this is expected and is the whole point of the split.

The final outer-app signing step must also pass the checked-in
`VoiceInk/VoiceInk.local.entitlements`. Replacing only the outer signature without that file can
silently remove `com.apple.security.automation.apple-events`, even while nested frameworks and
`codesign --verify --deep --strict` still pass. Treat the final entitlement dump as a separate release
gate whenever exact Terminal/iTerm delivery is included.

Do not trust this requirement to documentation alone: the actual Mac Mini helper was still signing
the outer app without entitlements during the v2.0.211 release. Its current interface accepts the
checked-in entitlements as argument 2, refuses a missing file, and verifies Automation after signing:

```sh
~/Projects/VoiceInk-build/resign-local.sh \
  ~/Downloads/VoiceInkPlusPlus.app \
  "$PWD/VoiceInk/VoiceInk.local.entitlements"
```

## Port upstream features one at a time

The 2026-07-15 audit found the fork 68 commits ahead and upstream 80 commits ahead of merge base
`eda0786`. A trial whole-branch merge produced 17 conflicts, including the destination, recorder,
pipeline, delivery, cloud-transcription, project, and test files. A whole upstream merge is therefore
not a supported update procedure.

The 2026-07-23 refresh fetched upstream again and found `upstream/main` still exactly at
`69ed170` (`Release VoiceInk 2.0`), the same tip already covered by that audit. No newer upstream
change existed to merge or port during the realtime-input work.

For each update:

1. Fetch upstream and audit the candidate in a disposable clone or worktree.
2. Ask Ethan to approve one user-visible feature.
3. Manually port only that feature onto a dedicated branch, preserving VoiceInk++'s adjacent intent
   comments, exact-destination contracts, marked vocabulary carrier, and error redaction.
4. Run the complete unit suite and the relevant disposable live matrix, then follow the numbered
   Mac Mini sign/install procedure above.
5. Commit and publish only the reviewed port. Never reset `main` or merge `upstream/main` wholesale.

The best candidates from that audit, in suggested order, are:

- `3a96487` + `a1f0dc6`: AVAssetReader fallback for imported MP4/M4A/Teams audio (PR #807).
- `d587497` + `d4dda90` + `9c24a8d` + `21e9322` + `23d7abc`: edit/test custom-model API keys and validate schemes, while retaining VoiceInk++ vocabulary and response redaction.
- `4be8719`: per-request URLSession to avoid remote custom-endpoint HTTP/3/VPN upload hangs; retain the fork's timeouts.
- `4c4b8fe` (merged as `eb76c75`): preferred-input-channel loopback exclusion.
- `3c965ee`: keep mini/notch recorder panels visible when the app hides.

Do not port `cde93d3` as written: it removes non-Whisper custom/cloud prompts and would delete the
marked prompt block that carries VoiceInk++ vocabulary to the local Deepgram adapter. Also skip the
large formatter-only `f20ac14`; it adds conflict without product behavior. Streaming, live-transcript,
media-muting, window-recovery, provider-list, and licensing changes remain deferred until Ethan asks
for those features and their local interaction tests are defined.

Sparkle remains disabled for local builds. The legacy Mini script
`~/.claude/scripts/voiceink-fork-update.sh` still exists, but its LaunchAgent is deliberately named
`com.ethansk.voiceink-fork-autoupdate.plist.DISABLED`; keep it disabled because its wholesale-merge
workflow is incompatible with the current fork.

## Settings / data

**As of the VoiceInk++ rebrand, this is now a SEPARATE app with its own bundle id**
(`com.ethansk.VoiceInkPlusPlus`), so it does **not** share prefs / Modes / app-support with the
official VoiceInk anymore. VoiceInk++'s data lives at:

- Prefs: `~/Library/Preferences/com.ethansk.VoiceInkPlusPlus.plist`
- App support / models / recordings: `~/Library/Application Support/com.ethansk.VoiceInkPlusPlus/`
- Keychain service: `com.ethansk.VoiceInkPlusPlus`

This is intentional — the split lets VoiceInk++ run alongside the official VoiceInk without TCC /
prefs collisions. To carry over your existing setup from the official app's
`com.prakashjoshipax.VoiceInk` store, copy/import the data manually (Settings → Import Settings, or
copy the Application Support folder). A pre-migration backup lives at `~/voiceink-settings-backup-*`.

> Historical note: before the rebrand this fork shared `com.prakashjoshipax.VoiceInk` with the
> official app, which is exactly the TCC/prefs collision the rebrand fixes.

# Updating this fork (EthanSK/VoiceInk) against upstream

This is Ethan's personal GPL-3.0 fork of [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk),
carrying a small set of local patches on top of upstream. Upstream **does not accept PRs**, so our
patches live only here and must be **merged** with each upstream release.

## Our patches (preserve these through every merge)

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
- **Per-recording destination control — choose the start or stop input at the end.** The normal
  recording shortcut stops into the exact input focused at stop. The macOS Next Track media key is
  intercepted only while actively recording and stops into the exact Accessibility input captured
  at recording start. When Electron/Chromium exposes only `AXWebArea` during the shortcut, it falls
  back to the recording-start application; outside recording Next Track continues to control media
  normally. Each
  `RecordingSession` owns its immutable start input and resolved paste target, preventing concurrent
  background transcriptions from mixing destinations. While the newest transcription is still
  loading, Next Track can replace its target with the input focused at that moment; the pipeline
  resolves the session's target only immediately before delivery. Delivery waits for cross-app activation,
  restores and verifies the exact element, and copies to the clipboard rather than pasting into an
  unintended field if verification fails. The post-stop Next Track action is a distinct second-chance
  route: while the newest result is loading it atomically replaces both the pending exact input and
  that target app's auto-send key, so moving to another app before delivery cannot remove Return.
  This is never a toggle and must not be confused with Next Track while recording, which stops into
  the recording-start input. See [Recording Destination Controls](RECORDING_DESTINATIONS.md)
  for user examples, setup, failure behavior, logs, and the implementation map.

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

## Pull in upstream changes (merge workflow)

```sh
git checkout main
git fetch origin upstream
git reset --hard origin/main       # origin/main is the source of truth for the fork
git merge --no-edit upstream/main # preserve fork history; do not rebase origin/main
# If conflicts: they'll likely be in ActiveWindowService.swift / VoiceInk.swift — keep BOTH
# upstream's changes and our observer/start() additions, then commit the resolved merge.
git push origin main
```
Then rebuild on the Mini (`make local`) and install the fresh `~/Downloads/VoiceInkPlusPlus.app` on the MBP.

Upstream auto-update (Sparkle) is disabled in local builds, so updating is this manual merge + Mini
rebuild — or the automated job below.

## Automated rebuild (keeps the build current with our fixes)

A scheduled job on the Mini (`~/.claude/scripts/voiceink-fork-update.sh` + a LaunchAgent) does the
above on a cadence: fetch upstream → merge upstream/main into the fork → `make local` → notify, and the new `.app` is
copied to the MBP. If a merge hits a conflict it stops and notifies (manual resolve) rather than
producing a broken build. See that script for details.

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

# Build VoiceInk++

VoiceInk++ is currently distributed as source. The local build path creates a standalone, ad-hoc signed `VoiceInkPlusPlus.app` without requiring a paid Apple Developer account.

## Requirements

- macOS 14.4 or later
- A recent full installation of Xcode
- Xcode Command Line Tools
- Git and Swift (both are included with the normal Xcode toolchain)
- Internet access on the first build for Swift packages and `whisper.cpp`

Confirm the command-line prerequisites:

```sh
xcode-select -p
git --version
swift --version
```

If `xcode-select` points at Command Line Tools instead of the full Xcode app, switch it before building:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

## Quick start

```sh
git clone https://github.com/EthanSK/VoiceInkPlusPlus.git
cd VoiceInkPlusPlus
make local
open ~/Downloads/VoiceInkPlusPlus.app
```

The first build takes longer because the Makefile prepares `whisper.xcframework` under `~/VoiceInk-Dependencies` and resolves the Swift package graph. Later builds reuse that dependency directory.

When the build succeeds, the standalone app is copied to:

```text
~/Downloads/VoiceInkPlusPlus.app
```

The bundle is named `VoiceInkPlusPlus.app`; macOS shows the user-facing name **VoiceInk++**.

## First launch

VoiceInk++ needs two macOS permissions for its core workflow:

1. **Microphone** — records your voice.
2. **Accessibility** — captures, restores, pastes into, and verifies the editable destination you chose.

Follow the in-app permission prompts. You can review the grants later in **System Settings → Privacy & Security**.

An ad-hoc local build is separate from the upstream VoiceInk app. It uses the bundle identifier `com.ethansk.VoiceInkPlusPlus`, so it does not replace `/Applications/VoiceInk.app`.

## Recommended mouse setup

After the app launches:

1. Configure the normal VoiceInk++ recording shortcut in toggle mode.
2. In your mouse software, assign one button to that shortcut.
3. Assign a second button to the standard macOS **Next Track** media action.
4. Read [RECORDING_DESTINATIONS.md](RECORDING_DESTINATIONS.md) for the three destination routes.

Ethan uses a Logitech G502 X LIGHTSPEED with Logitech G HUB, but any programmable mouse that can emit the configured shortcut and Next Track can reproduce the workflow.

## Make targets

| Command | Purpose |
| --- | --- |
| `make check` | Verify Git, Xcode's build tools, and Swift |
| `make whisper` | Prepare `whisper.xcframework` in `~/VoiceInk-Dependencies` |
| `make setup` | Confirm the Whisper framework is available |
| `make local` | Build and copy the standalone VoiceInk++ app to `~/Downloads` |
| `make build` | Build the normal Debug configuration |
| `make run` | Open the available VoiceInk++ build |
| `make dev` | Build and run for development |
| `make clean` | Remove the shared dependency directory |
| `make help` | List the available targets |

When starting an installed background build, use `open -g /Applications/VoiceInkPlusPlus.app`.
Never add `-j`: that globally hides the application, and AppKit cannot put any recorder panel on
screen while its owner remains hidden. VoiceInk++ defensively recovers that state at HUD
presentation, but the release launcher must not create it.

## Local-build limitations

The ad-hoc local configuration intentionally omits capabilities that require Ethan's Apple signing setup:

- No iCloud dictionary sync
- No automatic install channel; VoiceInk++ can check the official VoiceInk GitHub releases once
  per day and notify you when a newer upstream release is available to review, but it never installs
  or merges that release. Pull reviewed VoiceInk++ source and rebuild instead.

Transcription providers may require your own API credentials. Ethan's personal Deepgram local proxy is not part of this repository.

## Run tests

During implementation, default to the smallest focused set that covers the changed behavior and its nearest contract guards. In Xcode, run individual tests or suites from the Test navigator. From Terminal, obtain the exact current test identifier from Xcode's Test navigator or a successful `.xcresult`, then repeat `-only-testing` for each selection. Do not hand-construct identifiers: Swift Testing and XCTest encode them differently, and an unmatched filter can select zero tests without making the command fail.

```sh
xcodebuild \
  -project VoiceInk.xcodeproj \
  -scheme VoiceInk \
  -destination 'platform=macOS' \
  '-only-testing:VoiceInkTests/<exact-suite-or-test-identifier>' \
  test
```

A focused run should normally include:

1. The regression test added or changed for the bug or feature.
2. The nearest invariant/contract tests for shared code touched by the change.
3. Any mandatory guard named in [AGENTS.md](AGENTS.md); destination-routing changes must include `secondChanceRetargetCarriesAutoSendUntilDeliveryResolvesIt` and the applicable Primary/Next route guard.

Widen to adjacent tests only when the change crosses their shared code or focused evidence shows fallout. Run the full unit suite only for one final pass at a release boundary, one post-change pass after broad/high-risk architecture work, or when focused failures indicate a wider regression. Do not repeatedly run the full suite after ordinary edits or documentation-only changes. The release-boundary pass must run against the exact commit and build number that will be signed and installed. When a full pass is required, use **Product → Test** or omit every `-only-testing` option from the command above.

For every focused run, require at least one test to execute and require the output to name every expected selected test. Do not count a successful build, a scheme-level `Test Succeeded`, or any zero-test result as a pass. Preserve a stalled or empty-selection log and retry the same focused selection; do not turn a routine stall or malformed filter into an unplanned full-suite run. Never use direct `xcrun xctest` to satisfy a focused selection. At one of the full-suite gates above, the already-built `VoiceInkTests.xctest` bundle may be run with `xcrun xctest` as a diagnostic fallback, setting `DYLD_LIBRARY_PATH` to the host app's `Contents/MacOS` and `DYLD_FRAMEWORK_PATH` to its `Contents/Frameworks` plus Xcode's macOS developer frameworks. A valid fallback run names every expected test. Retry the normal Xcode runner after recovering TestManager, and do not enable Developer Mode unless the Mac owner explicitly chooses to.

## Troubleshooting

### Xcode license or first-launch error

Open Xcode once and finish its component installation, then run:

```sh
sudo xcodebuild -license accept
```

### Swift packages do not resolve

Check the network connection, open the project in Xcode, and use **File → Packages → Reset Package Caches** before retrying `make local`.

### The app cannot record or paste

Verify both Microphone and Accessibility access in System Settings. After rebuilding, macOS may treat the new ad-hoc signature as a fresh app and ask for permission again.

Exact Apple Terminal/iTerm delivery also needs the optional Automation grant shown on first use. If the first native terminal attempt times out or fails, open **System Settings → Privacy & Security → Automation**, allow VoiceInk++ to control that terminal host, then retry on a disposable tab/pane.

If you re-sign a local build after Xcode finishes, the outer app signature must explicitly use `VoiceInk/VoiceInk.local.entitlements`. A generic replacement signature can remove the Automation entitlement even when `codesign --verify --deep --strict` still accepts the nested bundle. Inspect the final outer entitlements and require `com.apple.security.automation.apple-events` to be true before testing Terminal or iTerm delivery.

On Ethan's Mac Mini, pass that checked-in file to the local signing helper explicitly:

```sh
~/Projects/VoiceInk-build/resign-local.sh \
  ~/Downloads/VoiceInkPlusPlus.app \
  "$PWD/VoiceInk/VoiceInk.local.entitlements"
```

The helper must fail closed when the file is missing and verify the outer Automation entitlement after signing. Do not assume the helper is safe merely because its certificate and deep/strict signature verify.

### The first build cannot find Whisper

Run the dependency step directly, then retry:

```sh
make whisper
make local
```

### Still blocked

Search the [VoiceInk++ issues](https://github.com/EthanSK/VoiceInkPlusPlus/issues) and open a new one with:

- macOS and Xcode versions
- the command you ran
- the first relevant build error
- whether this was a first build or an update

Do not include API keys, tokens, private proxy URLs, or other credentials in issue logs.

## Upstream project

VoiceInk++ is an independent fork of [VoiceInk by Beingpax](https://github.com/Beingpax/VoiceInk). Upstream build and download instructions install VoiceInk, not this VoiceInk++ fork.

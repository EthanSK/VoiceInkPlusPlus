import Foundation
import AppKit
import ApplicationServices // AXUIElement* APIs — used to resolve the *keyboard-focused* app (see chatgpt-floating-window fix below)
import os

class ActiveWindowService: ObservableObject {
    struct ConfigurationResolution {
        /// App/default (or explicit) Mode applied synchronously at the decision point.
        let immediateConfiguration: ModeConfig?
        /// The same decision, optionally refined by that captured browser tab's URL.
        /// Returning the value prevents callers from re-reading unrelated global Mode
        /// after another app activation while the URL lookup was suspended.
        let finalConfiguration: Task<ModeConfig?, Never>
    }

    static let shared = ActiveWindowService()
    @Published var currentApplication: NSRunningApplication?
    private let browserURLService = BrowserURLService.shared

    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "browser.detection"
    )

    // Observer token for the NSWorkspace app-activation notification.
    // We keep it so the observer can (in principle) be torn down; in practice
    // this singleton lives for the whole app lifetime, so it's never removed.
    // Stored to avoid registering the observer more than once.
    private var didActivateObserver: NSObjectProtocol?

    private init() {}

    @MainActor
    func updateCurrentApplicationForDisplay(_ application: NSRunningApplication) {
        guard application.bundleIdentifier != Bundle.main.bundleIdentifier,
              !application.isTerminated else {
            return
        }
        currentApplication = application
    }

    // MARK: - Follow-the-frontmost-app support (issue #785)
    //
    // The bug: VoiceInk resolved the active Mode ONLY at record-start, from the
    // frontmost app at that exact instant. Ethan's workflow is "start recording
    // first, THEN click into the target app", so the wrong app's Mode was applied
    // (right paste target, but wrong auto-send behavior).
    //
    // The fix: observe NSWorkspace app-activation events and re-resolve the active
    // Mode every time the frontmost app changes — including switches DURING a
    // recording. Output mode + auto-send are read LIVE at delivery from
    // ModeManager.currentEffectiveConfiguration, so updating the active config as
    // the user moves between apps makes delivery match the app they actually end in.
    //
    // VoiceInk's recorder windows are .nonactivatingPanel, so they do NOT become
    // frontmost — genuine app switches still fire didActivateApplicationNotification
    // even while a recording is in progress. That's what makes this approach work.
    //
    // Call this exactly once, early in app launch. It's idempotent (guards against
    // double-registration) so a stray second call is harmless.
    func start() {
        guard didActivateObserver == nil else { return }

        didActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Pull the newly-activated app out of the notification's userInfo.
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            // The notification queue is .main, but the handler isn't statically
            // isolated to the main actor — hop on explicitly so we can safely touch
            // @Published state and main-actor-only ModeManager APIs.
            Task { @MainActor [weak self] in
                self?.handleFrontmostAppActivation(app)
            }
        }
    }

    // Re-resolve and apply the active Mode for a newly-activated app.
    // Mirrors the resolution in beginApplyingConfiguration (app config -> default
    // -> neutral nil) so record-start and live-follow behave identically.
    @MainActor
    private func handleFrontmostAppActivation(_ app: NSRunningApplication) {
        guard let bundleIdentifier = app.bundleIdentifier else { return }

        // Ignore activations of VoiceInk itself — when the user clicks back into our
        // own window (e.g. settings, or the recorder if it ever takes focus) we must
        // NOT replace the last real target app shown in the recorder or clobber its Mode.
        if bundleIdentifier == Bundle.main.bundleIdentifier { return }

        // The recorder now shows the genuinely current app separately from the
        // per-session locked paste destination. Keep this visual signal current even
        // when a focus lock suppresses Mode re-resolution below.
        updateCurrentApplicationForDisplay(app)

        // Feature A (focus lock): if a long-press focus lock is active, the user has
        // DELIBERATELY pinned delivery to the field they started in. Suppress the
        // #785 frontmost-follow for this session — otherwise clicking into another
        // app mid-recording would re-resolve the Mode/auto-send to that other app,
        // which is exactly the behavior the lock is meant to override. The locked
        // session keeps whatever Mode was resolved at record-start.
        if FocusLockService.shared.isLockActive { return }

        // Same resolution order used at record-start. resolveAndApplyConfiguration
        // also handles the neutral-nil fallback (issue #784) and the async
        // browser-URL override.
        resolveAndApplyConfiguration(
            for: bundleIdentifier,
            applicationBundleName: app.bundleURL?.lastPathComponent,
            shouldApply: { [weak self] in
                self?.currentApplication?.processIdentifier
                    == app.processIdentifier
            }
        )
    }

    // Shared resolution used by BOTH the record-start path and the live-follow
    // observer: app-config -> default-config -> neutral(nil). Applies the result and,
    // for browsers, kicks off the async URL-based override (identical to the prior
    // inline logic). `shouldApply` lets the record-start caller bail if the recording
    // was cancelled between resolution steps; the observer always passes { true }.
    @MainActor
    @discardableResult
    private func resolveAndApplyConfiguration(
        for bundleIdentifier: String,
        applicationBundleName: String? = nil,
        applyGlobally: Bool = true,
        allowBrowserURLRefinement: Bool = true,
        shouldApply: @escaping @MainActor () -> Bool
    ) -> ConfigurationResolution {
        let modeBundleIdentifier = Self.modeLookupBundleIdentifier(
            capturedBundleIdentifier: bundleIdentifier,
            applicationBundleName: applicationBundleName
        )
        let quickConfig = ModeManager.shared.getConfigurationForApp(
            modeBundleIdentifier
        )
            ?? ModeManager.shared.getDefaultConfiguration()

        if applyGlobally, shouldApply() {
            if let quickConfig {
                ModeManager.shared.setActiveConfiguration(quickConfig)
            } else {
                // Issue #784: no app-specific Mode AND no default Mode -> apply a neutral
                // config (nil) instead of leaving the previously-active Mode in place.
                // Delivery treats nil as plain paste / no auto-send (ModeRuntimeConfiguration),
                // so a stale Mode from a prior app can't leak its auto-send behavior here.
                ModeManager.shared.setActiveConfiguration(nil)
            }
        }

        guard allowBrowserURLRefinement,
              let browserType = BrowserType.allCases.first(where: {
                  $0.bundleIdentifier == bundleIdentifier
              }) else {
            return ConfigurationResolution(
                immediateConfiguration: quickConfig,
                finalConfiguration: Task { quickConfig }
            )
        }

        // Browser: asynchronously fetch the current tab URL and, if a URL-specific
        // Mode matches, override the app-level Mode chosen above.
        let finalConfiguration = Task { [weak self] in
            guard let self else { return quickConfig }

            do {
                let currentURL = try await self.browserURLService.getCurrentURL(from: browserType)
                let urlConfiguration = await MainActor.run {
                    ModeManager.shared.getConfigurationForURL(currentURL)
                }
                guard let urlConfiguration else { return quickConfig }
                await MainActor.run {
                    guard applyGlobally, shouldApply() else { return }
                    ModeManager.shared.setActiveConfiguration(urlConfiguration)
                }
                return urlConfiguration
            } catch is CancellationError {
                return quickConfig
            } catch {
                self.logger.error("❌ Failed to get URL from \(browserType.displayName, privacy: .public): \(error, privacy: .public)")
                return quickConfig
            }
        }
        return ConfigurationResolution(
            immediateConfiguration: quickConfig,
            finalConfiguration: finalConfiguration
        )
    }

    /// Resolve the Mode owned by one exact destination decision without consuming or
    /// mutating the global live Mode. Primary stop and second-chance Next call this at
    /// the same boundary as Accessibility input capture. Because that capture does not
    /// prove a browser tab identity, the result deliberately freezes only the captured
    /// app/default Mode; URL refinement stays disabled until a window+tab-bound resolver
    /// exists. This prevents a later tab or global-focus change from changing the Mode
    /// attached to the saved input.
    @MainActor
    func resolveConfigurationForCapturedTarget(
        bundleIdentifier: String,
        applicationBundleName: String?
    ) -> ConfigurationResolution {
        // A destination capture currently owns an exact app/input but not a browser
        // tab identity. Reading "the current URL" after this method returns can race a
        // tab switch and attach another tab's formatting or auto-send behavior to the
        // saved input. Keep the synchronous app/default Mode until a window+tab-bound
        // URL resolver exists; the exact destination and its Mode stay atomic.
        resolveAndApplyConfiguration(
            for: bundleIdentifier,
            applicationBundleName: applicationBundleName,
            applyGlobally: false,
            allowBrowserURLRefinement: false,
            shouldApply: { false }
        )
    }

    /// Some OpenAI builds report ChatGPT with Codex's bundle identifier. The saved
    /// launch instance still exposes its bundle URL, so map only that proven
    /// ChatGPT.app case to the existing ChatGPT Mode key; Codex.app keeps Codex's key.
    static func modeLookupBundleIdentifier(
        capturedBundleIdentifier: String,
        applicationBundleName: String?
    ) -> String {
        if capturedBundleIdentifier == "com.openai.codex",
           applicationBundleName == "ChatGPT.app" {
            return "com.openai.chat"
        }
        return capturedBundleIdentifier
    }

    // MARK: - Keyboard-focused-app resolution (ChatGPT floating-window fix)
    //
    // THE BUG this guards against:
    // The ChatGPT macOS app's floating "companion / quick-access" window (summoned
    // with a global hotkey, floats over whatever app you're in) is a
    // NON-ACTIVATING panel (.nonactivatingPanel, like Spotlight/an accessory window).
    // macOS deliberately lets such a panel take KEYBOARD focus WITHOUT changing
    // `NSWorkspace.shared.frontmostApplication` and WITHOUT firing
    // `didActivateApplicationNotification`. So when Ethan dictates into that floating
    // window, our two existing app-resolution paths both miss it:
    //   • record-start read of `frontmostApplication` (beginApplyingConfiguration) →
    //     still points at whatever real app was front BEHIND the panel, not ChatGPT.
    //   • the live-follow observer (didActivateApplicationNotification) → never fires
    //     for a non-activating panel, so it can't correct it either.
    // Net effect: the per-app "ChatGPT mode" never activates → no auto-Enter, and the
    // menu-bar "Mode:" indicator (MenuBarView reads currentEffectiveConfiguration)
    // stays on the wrong mode. It only worked when ChatGPT's MAIN window was front
    // (a normal window that DOES become frontmost).
    //
    // THE FIX:
    // Ask the Accessibility API which app actually owns KEYBOARD focus. Unlike
    // `frontmostApplication`, the system-wide AX focused element DOES follow into a
    // non-activating panel, so it correctly reports ChatGPT (com.openai.chat) while
    // that floating window is focused. We use this as the PRIMARY signal at
    // record-start and fall back to `frontmostApplication` whenever AX can't help.
    //
    // WHY THIS IS SAFE / ADDITIVE for ordinary apps:
    // For a normal window, the AX-focused app IS the frontmost app, so behavior is
    // unchanged. We only diverge from the old logic in exactly the broken case
    // (focus sitting in a non-activating panel). Reuses the same AX pattern already
    // proven in FocusLockService.captureCandidate (system-wide element → pid → app).
    //
    // FALLBACK CASES (return nil → caller uses frontmostApplication):
    //   • Accessibility not granted (AXIsProcessTrusted() == false).
    //   • No system-wide focused element, or no resolvable owning app.
    //   • The focused app is VoiceInk ITSELF — our own recorder windows are ALSO
    //     non-activating panels, so we must never attribute focus to ourselves and
    //     clobber the user's real target app's mode.
    // Cheap + only called once per record-start (not polled), so no AX hammering.
    private func accessibilityFocusedApplication() -> NSRunningApplication? {
        // No Accessibility permission → can't read system-wide focus. Bail to the
        // frontmost path. (VoiceInk already requests AX since it injects keystrokes.)
        guard AXIsProcessTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )

        // Some focus contexts don't expose a focused AX element — fall back.
        guard result == .success, let focusedRef else { return nil }

        // Successful read of kAXFocusedUIElementAttribute always yields an AXUIElement.
        let element = focusedRef as! AXUIElement

        // Map the focused element → owning process → NSRunningApplication so we can
        // read its bundle id for per-app mode lookup.
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid),
              let bundleIdentifier = app.bundleIdentifier,
              !bundleIdentifier.isEmpty,
              !app.isTerminated else {
            return nil
        }

        // Never attribute focus to VoiceInk itself (our recorder panels are also
        // non-activating). Guard by both PID and bundle id, then fall back so the
        // caller resolves the real target app via frontmostApplication instead.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return nil
        }
        if let ownBundleIdentifier = Bundle.main.bundleIdentifier,
           bundleIdentifier == ownBundleIdentifier {
            return nil
        }

        return app
    }

    @MainActor
    @discardableResult
    func beginApplyingConfiguration(
        modeId: UUID? = nil,
        preferredApplication: NSRunningApplication? = nil,
        shouldApply: @escaping @MainActor () -> Bool = { true }
    ) -> ConfigurationResolution {
        if let modeId = modeId,
           let config = ModeManager.shared.getConfiguration(with: modeId) {
            guard shouldApply() else {
                return ConfigurationResolution(
                    immediateConfiguration: nil,
                    finalConfiguration: Task { nil }
                )
            }
            ModeManager.shared.setActiveConfiguration(config)
            return ConfigurationResolution(
                immediateConfiguration: config,
                finalConfiguration: Task { config }
            )
        }

        // Prefer the KEYBOARD-focused app (Accessibility) over the frontmost app, so
        // dictating into a non-activating panel like ChatGPT's floating companion
        // window correctly resolves to ChatGPT (com.openai.chat) and activates its
        // per-app mode (incl. auto-Enter). Falls back to frontmostApplication when AX
        // can't help (untrusted / no focused element / focus is VoiceInk itself).
        // For ordinary windows these two are the same app, so this is non-breaking.
        let activeApp: NSRunningApplication?
        if let preferredApplication {
            // A non-nil preferred app is an exact capture decision, not a hint. If
            // that launch instance terminated, falling back to current focus would
            // stamp an unrelated app's Mode onto recordingStart.
            activeApp = preferredApplication.isTerminated
                ? nil
                : preferredApplication
        } else {
            activeApp = accessibilityFocusedApplication()
                ?? NSWorkspace.shared.frontmostApplication
        }

        guard let activeApp,
              let bundleIdentifier = activeApp.bundleIdentifier else {
            // No input/app identity means no Mode identity. Returning the previous
            // global Mode would stamp an unrelated app's formatting/Return behavior
            // onto this new recording, so unresolved startup is deliberately neutral.
            return ConfigurationResolution(
                immediateConfiguration: nil,
                finalConfiguration: Task { nil }
            )
        }

        guard shouldApply() else {
            return ConfigurationResolution(
                immediateConfiguration: nil,
                finalConfiguration: Task { nil }
            )
        }
        currentApplication = activeApp
        let activeProcessIdentifier = activeApp.processIdentifier

        // Delegate to the shared resolver (app-config -> default -> neutral nil, plus
        // the async browser-URL override). This is the SAME logic the live-follow
        // observer uses, so record-start and app-switch stay in sync. The neutral-nil
        // fallback (issue #784) now also applies here.
        return resolveAndApplyConfiguration(
            for: bundleIdentifier,
            applicationBundleName: activeApp.bundleURL?.lastPathComponent,
            // preferredApplication comes from a captured exact input/app but carries
            // no stable browser-tab identity. Do not let a suspended URL lookup bind
            // whichever tab happens to be current later.
            allowBrowserURLRefinement: preferredApplication == nil,
            shouldApply: { [weak self] in
                guard shouldApply(), let self else { return false }
                // ChatGPT.app and Codex.app can share a bundle identifier. Keep the
                // asynchronous refinement attached to the exact captured process rather
                // than whichever sibling application happens to be returned first.
                return self.currentApplication?.processIdentifier
                    == activeProcessIdentifier
            }
        )
    }

    func applyConfiguration(modeId: UUID? = nil) async {
        let resolution = await MainActor.run {
            beginApplyingConfiguration(modeId: modeId)
        }
        _ = await resolution.finalConfiguration.value
    }
}

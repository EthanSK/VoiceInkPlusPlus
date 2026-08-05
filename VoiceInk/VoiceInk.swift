import SwiftUI
import SwiftData
import AppKit
import OSLog
import AppIntents
import FluidAudio
import UserNotifications

@main
struct VoiceInkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    let container: ModelContainer

    @StateObject private var engine: VoiceInkEngine
    @StateObject private var whisperModelManager: WhisperModelManager
    @StateObject private var fluidAudioModelManager: FluidAudioModelManager
    @StateObject private var transcriptionModelManager: TranscriptionModelManager
    @StateObject private var recorderUIManager: RecorderUIManager
    @StateObject private var recordingShortcutManager: RecordingShortcutManager
    @StateObject private var updaterViewModel: UpdaterViewModel
    @StateObject private var menuBarManager: MenuBarManager
    @StateObject private var aiService = AIService()
    @StateObject private var enhancementService: AIEnhancementService
    @StateObject private var activeWindowService = ActiveWindowService.shared
    @AppStorage("hasCompletedOnboardingV2") private var hasCompletedOnboardingV2 = false
    @State private var showMenuBarIcon = true
    @State private var didShowAccessibilityReminder = false

    // Audio cleanup manager for automatic deletion of old audio files
    private let audioCleanupManager = AudioCleanupManager.shared

    // Transcription auto-cleanup service for zero data retention
    private let transcriptionAutoCleanupService = TranscriptionAutoCleanupService.shared

    // Model prewarm service for optimizing model on wake from sleep
    @StateObject private var prewarmService: ModelPrewarmService

    init() {
        // Disable HTTP response caching — prevents API responses from being stored in Cache.db
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)

        // Hold an app-lifetime activity assertion so macOS App Nap can't throttle our main
        // run loop while the Mac is idle. Without this the global record-hotkey CGEventTap
        // (whose run-loop source lives on the main run loop) gets disabled after a long idle
        // period, so the first press(es) after idle do nothing. See AppNapGuard for the full
        // explanation of the idle-miss bug. Must run first, before any heavy init work.
        _ = AppNapGuard.shared

        AppDefaults.registerDefaults()
        OnboardingV2Migration.prepareIfNeeded()

        let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Initialization")
        // Keep existing model order stable; append new models after synced entities.
        let schema = Schema([
            Transcription.self,
            VocabularyWord.self,
            WordReplacement.self,
            SessionMetric.self
        ])
        let resolvedContainer: ModelContainer

        // Attempt 1: Try persistent storage
        do {
            resolvedContainer = try Self.createPersistentContainer(schema: schema, logger: logger)
        } catch let persistentError {
            // Attempt 2: Try in-memory storage
            do {
                resolvedContainer = try Self.createInMemoryContainer(schema: schema, logger: logger)
                logger.warning("Using in-memory storage as fallback. Data will not persist between sessions.")

                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Storage Warning")
                    alert.informativeText = String(localized: "VoiceInk couldn't access its storage location. Your transcriptions will not be saved between sessions.")
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: String(localized: "OK"))
                    alert.runModal()
                }
            } catch let memoryError {
                let persistentDetail = Self.fullErrorDescription(persistentError)
                let memoryDetail = Self.fullErrorDescription(memoryError)
                logger.critical("❌ All ModelContainer init attempts failed.\nPersistent:\n\(persistentDetail, privacy: .public)\nIn-memory:\n\(memoryDetail, privacy: .public)")
                fatalError("VoiceInk failed to initialize storage.\nPersistent:\n\(persistentDetail)\nIn-memory:\n\(memoryDetail)")
            }
        }

        container = resolvedContainer
        // Run before any retention/orphan cleanup starts. A force-quit can leave a
        // complete PCM payload whose ExtAudioFile header was never finalized; this
        // converts only our journaled PCM16 captures into recovery-pinned History rows.
        // It never resumes a provider, resolves an input, pastes, or sends text.
        let crashRecoverySummary = RecordingCrashRecoveryService.recoverPendingRecordings(
            modelContext: resolvedContainer.mainContext
        )
        DictionaryService.removeExactDuplicateContent(context: resolvedContainer.mainContext, source: "launch")

        // Initialize services with proper sharing of instances
        let aiService = AIService()
        _aiService = StateObject(wrappedValue: aiService)
        aiService.refreshOllamaAvailabilityInBackground()

        let updaterViewModel = UpdaterViewModel()
        _updaterViewModel = StateObject(wrappedValue: updaterViewModel)

        let enhancementService = AIEnhancementService(aiService: aiService, modelContext: resolvedContainer.mainContext)
        _enhancementService = StateObject(wrappedValue: enhancementService)

        // 1. Create modelsDirectory URL
        // Standalone-fork identity: Application Support folder keyed to the new bundle id so
        // VoiceInk++ stores its models/data separately from the official VoiceInk install.
        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.ethansk.VoiceInkPlusPlus")
        let modelsDirectory = appSupportDirectory.appendingPathComponent("WhisperModels")

        // 2. Create model managers
        let whisperModelManager = WhisperModelManager(modelsDirectory: modelsDirectory)
        let fluidAudioModelManager = FluidAudioModelManager()
        let transcriptionModelManager = TranscriptionModelManager(
            whisperModelManager: whisperModelManager,
            fluidAudioModelManager: fluidAudioModelManager
        )

        // 3. Create UI manager
        let recorderUIManager = RecorderUIManager()

        // 4. Create engine
        let engine = VoiceInkEngine(
            modelContext: resolvedContainer.mainContext,
            whisperModelManager: whisperModelManager,
            transcriptionModelManager: transcriptionModelManager,
            enhancementService: enhancementService
        )

        // 5. Configure circular deps
        recorderUIManager.configure(engine: engine, recorder: engine.recorder)
        engine.recorderUIManager = recorderUIManager

        // 6. Initialize model state
        // Migration and refreshAllAvailableModels must run before loadCurrentTranscriptionModel so renamed keys are remapped and imported models are present when restoring the saved selection.
        StreamingKeysMigration.run()
        whisperModelManager.createModelsDirectoryIfNeeded()
        whisperModelManager.loadAvailableModels()
        transcriptionModelManager.refreshAllAvailableModels()
        transcriptionModelManager.loadCurrentTranscriptionModel()

        _whisperModelManager = StateObject(wrappedValue: whisperModelManager)
        _fluidAudioModelManager = StateObject(wrappedValue: fluidAudioModelManager)
        _transcriptionModelManager = StateObject(wrappedValue: transcriptionModelManager)
        _recorderUIManager = StateObject(wrappedValue: recorderUIManager)
        _engine = StateObject(wrappedValue: engine)

        // 7. Create other services that depend on engine
        let recordingShortcutManager = RecordingShortcutManager(engine: engine, recorderUIManager: recorderUIManager)
        _recordingShortcutManager = StateObject(wrappedValue: recordingShortcutManager)

        let menuBarManager = MenuBarManager()
        _menuBarManager = StateObject(wrappedValue: menuBarManager)
        menuBarManager.configure(modelContainer: resolvedContainer, engine: engine)

        let activeWindowService = ActiveWindowService.shared
        _activeWindowService = StateObject(wrappedValue: activeWindowService)
        // Start observing frontmost-app changes so the active Mode FOLLOWS the app the
        // user switches into (issue #785). Without this, the Mode was only resolved at
        // record-start; Ethan starts recording first then clicks into the target app,
        // so the wrong app's auto-send behavior was applied. start() is idempotent.
        activeWindowService.start()

        let prewarmService = ModelPrewarmService(
            transcriptionModelManager: transcriptionModelManager,
            whisperModelManager: whisperModelManager,
            modelContext: resolvedContainer.mainContext
        )
        _prewarmService = StateObject(wrappedValue: prewarmService)

        appDelegate.menuBarManager = menuBarManager
        // Cooperative quits (including Codex's signed-app replacement flow) must
        // consult the live session collection before terminating. This prevents a
        // release restart from cutting off microphone audio or queued transcription.
        appDelegate.voiceInkEngine = engine

        // Ensure no lingering recording state from previous runs
        Task {
            await recorderUIManager.resetOnLaunch()
            if crashRecoverySummary.recoveredCount > 0 {
                NotificationManager.shared.showNotification(
                    title: String(
                        format: String(localized: "Recovered %d interrupted recording(s) in History"),
                        crashRecoverySummary.recoveredCount
                    ),
                    type: .info,
                    duration: 6
                )
            }
            if crashRecoverySummary.retainedForManualRecoveryCount > 0 {
                NotificationManager.shared.showNotification(
                    title: String(
                        format: String(localized: "%d interrupted recording(s) were kept for manual recovery"),
                        crashRecoverySummary.retainedForManualRecoveryCount
                    ),
                    type: .error,
                    playSound: false
                )
            }
        }

        AppShortcuts.updateAppShortcutParameters()

        let migrationTask = SessionMetricMigrationService.shared.runIfNeeded(modelContainer: resolvedContainer)
        let mainContext = resolvedContainer.mainContext
        Task {
            await migrationTask?.value
            TranscriptionAutoCleanupService.shared.startMonitoring(modelContext: mainContext)
        }
    }

    // MARK: - Container Creation Helpers

    private static func fullErrorDescription(_ error: Error, depth: Int = 0) -> String {
        let ns = error as NSError
        let indent = String(repeating: "  ", count: depth)
        var lines: [String] = []
        lines.append("\(indent)[\(ns.domain) \(ns.code)] \(ns.localizedDescription)")
        for (key, value) in ns.userInfo {
            let keyStr = "\(key)"
            if keyStr == NSUnderlyingErrorKey || keyStr == "NSDetailedErrors" { continue }
            lines.append("\(indent)  \(keyStr): \(value)")
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            lines.append("\(indent)  Underlying:")
            lines.append(fullErrorDescription(underlying, depth: depth + 2))
        }
        if let details = ns.userInfo["NSDetailedErrors"] as? [Error] {
            lines.append("\(indent)  DetailedErrors (\(details.count)):")
            for (i, detail) in details.enumerated() {
                lines.append("\(indent)    [\(i)]:")
                lines.append(fullErrorDescription(detail, depth: depth + 3))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func createPersistentContainer(schema: Schema, logger: Logger) throws -> ModelContainer {
        // Standalone-fork identity: SwiftData store lives under the new bundle id's Application
        // Support folder so VoiceInk++ never shares its DB with the official VoiceInk.
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.ethansk.VoiceInkPlusPlus", isDirectory: true)

        try? FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

        let defaultStoreURL = appSupportURL.appendingPathComponent("default.store")
        let dictionaryStoreURL = appSupportURL.appendingPathComponent("dictionary.store")
        let statsStoreURL = appSupportURL.appendingPathComponent("stats.store")

        let transcriptSchema = Schema([Transcription.self])
        let transcriptConfig = ModelConfiguration(
            "default",
            schema: transcriptSchema,
            url: defaultStoreURL,
            cloudKitDatabase: .none
        )

        let dictionarySchema = Schema([VocabularyWord.self, WordReplacement.self])
        #if LOCAL_BUILD
        let dictionaryCloudKit: ModelConfiguration.CloudKitDatabase = .none
        #else
        // iCloud container intentionally left as the upstream id — it must match a PROVISIONED
        // CloudKit container in the Apple Developer account, and we haven't created a new one.
        // This branch only runs in signed (non-LOCAL_BUILD) builds; Ethan's `make local` path uses
        // the .none branch above, so the old id is inert for his standalone VoiceInk++ build.
        let dictionaryCloudKit: ModelConfiguration.CloudKitDatabase = .private("iCloud.com.prakashjoshipax.VoiceInk")
        #endif
        let dictionaryConfig = ModelConfiguration(
            "dictionary",
            schema: dictionarySchema,
            url: dictionaryStoreURL,
            cloudKitDatabase: dictionaryCloudKit
        )

        let statsSchema = Schema([SessionMetric.self])
        let statsConfig = ModelConfiguration(
            "stats",
            schema: statsSchema,
            url: statsStoreURL,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(for: schema, configurations: transcriptConfig, dictionaryConfig, statsConfig)
        } catch {
            logger.error("❌ Failed to create persistent ModelContainer:\n\(Self.fullErrorDescription(error), privacy: .public)")
            throw error
        }
    }

    private static func createInMemoryContainer(schema: Schema, logger: Logger) throws -> ModelContainer {
        let transcriptSchema = Schema([Transcription.self])
        let transcriptConfig = ModelConfiguration("default", schema: transcriptSchema, isStoredInMemoryOnly: true)

        let dictionarySchema = Schema([VocabularyWord.self, WordReplacement.self])
        let dictionaryConfig = ModelConfiguration("dictionary", schema: dictionarySchema, isStoredInMemoryOnly: true)

        let statsSchema = Schema([SessionMetric.self])
        let statsConfig = ModelConfiguration("stats", schema: statsSchema, isStoredInMemoryOnly: true)

        do {
            return try ModelContainer(for: schema, configurations: transcriptConfig, dictionaryConfig, statsConfig)
        } catch {
            logger.error("❌ Failed to create in-memory ModelContainer:\n\(Self.fullErrorDescription(error), privacy: .public)")
            throw error
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboardingV2 {
                    ContentView()
                        .environmentObject(engine)
                        .environmentObject(whisperModelManager)
                        .environmentObject(fluidAudioModelManager)
                        .environmentObject(transcriptionModelManager)
                        .environmentObject(recorderUIManager)
                        .environmentObject(recordingShortcutManager)
                        .environmentObject(updaterViewModel)
                        .environmentObject(menuBarManager)
                        .environmentObject(aiService)
                        .environmentObject(enhancementService)
                        .modelContainer(container)
                        .onAppear {
                            showAccessibilityReminderIfNeeded()

                            // Start the automatic audio cleanup process only if transcript cleanup is not enabled
                            if !UserDefaults.standard.bool(forKey: "IsTranscriptionCleanupEnabled") {
                                audioCleanupManager.startAutomaticCleanup(modelContext: container.mainContext)
                            }

                            // Process any pending open-file request now that the main ContentView is ready.
                            if let pendingURL = appDelegate.pendingOpenFileURL {
                                NotificationCenter.default.post(name: .navigateToDestination, object: nil, userInfo: ["destination": "Transcribe Audio"])
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    NotificationCenter.default.post(name: .openFileForTranscription, object: nil, userInfo: ["url": pendingURL])
                                }
                                appDelegate.pendingOpenFileURL = nil
                            }
                        }
                        .background(WindowAccessor { window in
                            WindowManager.shared.configureWindow(window)
                        })
                        .onDisappear {
                            whisperModelManager.unloadModel()

                            // Stop the automatic audio cleanup process
                            audioCleanupManager.stopAutomaticCleanup()
                        }
                } else {
                    OnboardingView(hasCompletedOnboardingV2: $hasCompletedOnboardingV2)
                        .environmentObject(fluidAudioModelManager)
                        .environmentObject(aiService)
                        .environmentObject(enhancementService)
                        .frame(width: 950)
                        .frame(minHeight: 730)
                        .background(WindowAccessor { window in
                            WindowManager.shared.configureWindow(window)
                        })
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 950, height: 730)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updaterViewModel: updaterViewModel)
            }
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environmentObject(engine)
                .environmentObject(whisperModelManager)
                .environmentObject(fluidAudioModelManager)
                .environmentObject(transcriptionModelManager)
                .environmentObject(recorderUIManager)
                .environmentObject(recordingShortcutManager)
                .environmentObject(menuBarManager)
                .environmentObject(updaterViewModel)
                .environmentObject(aiService)
                .environmentObject(enhancementService)
        } label: {
            let image: NSImage = {
                let ratio = $0.size.height / $0.size.width
                $0.size.height = 22
                $0.size.width = 22 / ratio
                return $0
            }(NSImage(named: "menuBarIcon")!)

            Image(nsImage: image)
        }
        .menuBarExtraStyle(.menu)

        #if DEBUG
        WindowGroup("Debug") {
            Button("Toggle Menu Bar Only") {
                menuBarManager.isMenuBarOnly.toggle()
            }
        }
        #endif
    }

    private func showAccessibilityReminderIfNeeded() {
        guard !didShowAccessibilityReminder else { return }
        didShowAccessibilityReminder = true

        guard !AXIsProcessTrusted() else { return }

        NotificationManager.shared.showNotification(
            title: String(localized: "Accessibility permission is not provided"),
            type: .warning,
            duration: 7.0,
            actionButton: (String(localized: "Open Settings"), Self.openAccessibilitySettings)
        )
    }

    private static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct VoiceInkUpstreamRelease: Decodable, Equatable {
    let tagName: String
    let name: String?
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
    }
}

enum VoiceInkUpdatePolicy {
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    static func isAutomaticCheckDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= automaticCheckInterval
    }

    static func isNewerRelease(_ releaseTag: String, than integratedUpstreamTag: String) -> Bool {
        normalizedVersion(releaseTag).compare(
            normalizedVersion(integratedUpstreamTag),
            options: .numeric
        ) == .orderedDescending
    }

    static func shouldNotify(
        releaseTag: String,
        integratedUpstreamTag: String,
        lastNotifiedTag: String?,
        checksEnabled: Bool
    ) -> Bool {
        checksEnabled
            && releaseTag != lastNotifiedTag
            && isNewerRelease(releaseTag, than: integratedUpstreamTag)
    }

    private static func normalizedVersion(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "v" || first == "V" else {
            return trimmed
        }
        return String(trimmed.dropFirst())
    }
}

private final class VoiceInkUpdateNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private static let releaseURLKey = "voiceInkUpstreamReleaseURL"

    static func content(for release: VoiceInkUpstreamRelease) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "There’s a VoiceInk update"
        let candidateName = release.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = candidateName.flatMap { $0.isEmpty ? nil : $0 } ?? release.tagName
        content.body = "\(displayName) is available upstream. Open it to review for VoiceInk++."
        content.sound = .default
        content.userInfo = [releaseURLKey: release.htmlURL.absoluteString]
        return content
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard
            let value = response.notification.request.content.userInfo[Self.releaseURLKey] as? String,
            let url = URL(string: value)
        else {
            return
        }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
final class UpdaterViewModel: ObservableObject {
    static let automaticChecksKey = "VIPPDailyUpdateChecksEnabled"
    static let lastAutomaticCheckKey = "VIPPLastDailyUpdateCheck"
    static let lastNotifiedReleaseKey = "VIPPLastNotifiedUpstreamRelease"

    // VoiceInk++ deliberately reviews and manually ports upstream changes. This is the
    // newest official VoiceInk release already represented by the fork, not VoiceInk++'s
    // independent build number. A newer tag produces a notification only—never an
    // automatic Sparkle install, source merge, or replacement of the running fork.
    static let integratedUpstreamReleaseTag = "v2.0"
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/Beingpax/VoiceInk/releases/latest"
    )!

    @Published private(set) var canCheckForUpdates = true
    @Published private(set) var automaticallyChecksForUpdates: Bool

    private let defaults: UserDefaults
    private let notificationCenter: UNUserNotificationCenter
    private let notificationDelegate = VoiceInkUpdateNotificationDelegate()
    private let logger = Logger(
        subsystem: "com.ethansk.VoiceInkPlusPlus",
        category: "UpdateCheck"
    )
    private var automaticCheckTimer: Timer?
    private var checkTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: UNUserNotificationCenter = .current()
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        automaticallyChecksForUpdates = defaults.bool(forKey: Self.automaticChecksKey)
        notificationCenter.delegate = notificationDelegate

        if automaticallyChecksForUpdates {
            requestNotificationAuthorization()
        }
        scheduleNextAutomaticCheck()
    }

    func setAutomaticallyChecksForUpdates(_ value: Bool) {
        automaticallyChecksForUpdates = value
        defaults.set(value, forKey: Self.automaticChecksKey)

        if value {
            requestNotificationAuthorization()
            scheduleNextAutomaticCheck()
        } else {
            automaticCheckTimer?.invalidate()
            automaticCheckTimer = nil
            checkTask?.cancel()
            checkTask = nil
            canCheckForUpdates = true
        }
    }

    func checkForUpdates() {
        performCheck(reason: .manual)
    }

    private enum CheckReason {
        case automatic
        case manual
    }

    private func scheduleNextAutomaticCheck() {
        automaticCheckTimer?.invalidate()
        automaticCheckTimer = nil
        guard automaticallyChecksForUpdates else { return }

        let now = Date()
        let lastCheck = defaults.object(forKey: Self.lastAutomaticCheckKey) as? Date
        guard !VoiceInkUpdatePolicy.isAutomaticCheckDue(lastCheck: lastCheck, now: now) else {
            performCheck(reason: .automatic)
            return
        }

        let nextCheck = lastCheck!.addingTimeInterval(
            VoiceInkUpdatePolicy.automaticCheckInterval
        )
        let timer = Timer(fire: nextCheck, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performCheck(reason: .automatic)
            }
        }
        automaticCheckTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func performCheck(reason: CheckReason) {
        guard canCheckForUpdates else { return }
        if reason == .automatic {
            guard automaticallyChecksForUpdates else { return }
        }
        if automaticallyChecksForUpdates {
            // A successful manual check is still a real check; count it toward the daily
            // cadence so opening Settings cannot cause a duplicate request moments later.
            defaults.set(Date(), forKey: Self.lastAutomaticCheckKey)
        }

        canCheckForUpdates = false
        checkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                canCheckForUpdates = true
                checkTask = nil
                scheduleNextAutomaticCheck()
            }

            do {
                let release = try await Self.fetchLatestRelease()
                let isNewer = VoiceInkUpdatePolicy.isNewerRelease(
                    release.tagName,
                    than: Self.integratedUpstreamReleaseTag
                )

                switch reason {
                case .automatic:
                    guard VoiceInkUpdatePolicy.shouldNotify(
                        releaseTag: release.tagName,
                        integratedUpstreamTag: Self.integratedUpstreamReleaseTag,
                        lastNotifiedTag: defaults.string(
                            forKey: Self.lastNotifiedReleaseKey
                        ),
                        checksEnabled: automaticallyChecksForUpdates
                    ) else {
                        logger.info(
                            "Daily upstream update check completed updateAvailable=\(isNewer, privacy: .public)"
                        )
                        return
                    }
                    await notifyAboutUpdate(release)
                    defaults.set(release.tagName, forKey: Self.lastNotifiedReleaseKey)

                case .manual:
                    if isNewer {
                        showInAppUpdateNotification(release)
                    } else {
                        NotificationManager.shared.showNotification(
                            title: String(localized: "VoiceInk is up to date"),
                            type: .success
                        )
                    }
                }
            } catch is CancellationError {
                logger.info("Upstream update check cancelled")
            } catch {
                logger.error("Upstream update check failed")
                if reason == .manual {
                    NotificationManager.shared.showNotification(
                        title: String(localized: "Couldn’t check for VoiceInk updates"),
                        type: .warning
                    )
                }
            }
        }
    }

    private static func fetchLatestRelease() async throws -> VoiceInkUpstreamRelease {
        var request = URLRequest(
            url: latestReleaseURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("VoiceInkPlusPlus", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard
            let response = response as? HTTPURLResponse,
            (200..<300).contains(response.statusCode)
        else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(VoiceInkUpstreamRelease.self, from: data)
    }

    private func requestNotificationAuthorization() {
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { [logger] _, error in
            if error != nil {
                logger.error("Update notification authorization request failed")
            }
        }
    }

    private func notifyAboutUpdate(_ release: VoiceInkUpstreamRelease) async {
        let settings = await notificationCenter.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            let request = UNNotificationRequest(
                identifier: "voiceink-upstream-update-\(release.tagName)",
                content: VoiceInkUpdateNotificationDelegate.content(for: release),
                trigger: nil
            )
            do {
                try await notificationCenter.add(request)
            } catch {
                logger.error("Native update notification delivery failed")
                showInAppUpdateNotification(release)
            }
        case .notDetermined, .denied:
            showInAppUpdateNotification(release)
        @unknown default:
            showInAppUpdateNotification(release)
        }
    }

    private func showInAppUpdateNotification(_ release: VoiceInkUpstreamRelease) {
        NotificationManager.shared.showNotification(
            title: String(localized: "There’s a VoiceInk update"),
            type: .info,
            duration: 12,
            actionButton: (String(localized: "View Release"), {
                NSWorkspace.shared.open(release.htmlURL)
            })
        )
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject var updaterViewModel: UpdaterViewModel

    var body: some View {
        Button("Check for Updates…", action: updaterViewModel.checkForUpdates)
            .disabled(!updaterViewModel.canCheckForUpdates)
    }
}

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                callback(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

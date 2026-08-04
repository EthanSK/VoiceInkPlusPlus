//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Testing
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ApplicationServices
@testable import VoiceInkPlusPlus

private actor TranscriptionQueueTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

@MainActor
private final class TranscriptionQueueTestState {
    var currentIdentities = Set<TranscriptionJobIdentity>()
    var events: [String] = []
}

struct VoiceInkTests {

    @Test @MainActor func abandonedShortcutCaptureRestoresItsPreviousBinding() {
        let action = ShortcutAction.mode(UUID())
        let originalShortcut = Shortcut.key(
            keyCode: UInt16(kVK_ANSI_R),
            modifierFlags: [.command, .shift]
        )
        ShortcutStore.restorePersistenceState(.stored(originalShortcut), for: action)
        defer { ShortcutStore.removeShortcutStorage(for: action) }

        let recorder = ShortcutRecorderModel()
        recorder.start(
            action: action,
            onCapture: { _ in },
            onStoredShortcutChanged: {}
        )

        #expect(ShortcutStore.shortcut(for: action) == nil)
        recorder.cancel()
        #expect(ShortcutStore.shortcut(for: action) == originalShortcut)
    }

    @Test @MainActor func completedShortcutCaptureCommitsOnlyTheReplacement() throws {
        let action = ShortcutAction.mode(UUID())
        let originalShortcut = Shortcut.key(
            keyCode: UInt16(kVK_F12),
            modifierFlags: [.control, .shift]
        )
        ShortcutStore.restorePersistenceState(.stored(originalShortcut), for: action)
        defer { ShortcutStore.removeShortcutStorage(for: action) }

        let replacement = try #require(
            [kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
                .map { Shortcut.key(keyCode: UInt16($0), modifierFlags: []) }
                .first { ShortcutValidator.validationError(for: $0, action: action) == nil }
        )
        let recorder = ShortcutRecorderModel()
        recorder.start(
            action: action,
            onCapture: { _ in },
            onStoredShortcutChanged: {}
        )
        recorder.finish(with: replacement)

        #expect(ShortcutStore.shortcut(for: action) == replacement)
        recorder.cancel()
        #expect(ShortcutStore.shortcut(for: action) == replacement)
    }

    @Test @MainActor func abandonedShortcutCapturePreservesUnsetState() {
        let action = ShortcutAction.mode(UUID())
        ShortcutStore.removeShortcutStorage(for: action)
        defer { ShortcutStore.removeShortcutStorage(for: action) }

        let recorder = ShortcutRecorderModel()
        recorder.start(
            action: action,
            onCapture: { _ in },
            onStoredShortcutChanged: {}
        )
        recorder.cancel()

        #expect(ShortcutStore.persistenceState(for: action) == .unset)
    }

    @Test @MainActor func abandonedShortcutCaptureDoesNotOverwriteANewerBinding() {
        let action = ShortcutAction.mode(UUID())
        let originalShortcut = Shortcut.key(keyCode: UInt16(kVK_F18), modifierFlags: [])
        let replacementShortcut = Shortcut.key(keyCode: UInt16(kVK_F19), modifierFlags: [])
        ShortcutStore.restorePersistenceState(.stored(originalShortcut), for: action)
        defer { ShortcutStore.removeShortcutStorage(for: action) }

        let recorder = ShortcutRecorderModel()
        recorder.start(
            action: action,
            onCapture: { _ in },
            onStoredShortcutChanged: {}
        )
        ShortcutStore.restorePersistenceState(.stored(replacementShortcut), for: action)
        recorder.cancel()

        #expect(ShortcutStore.shortcut(for: action) == replacementShortcut)
    }

    @Test @MainActor func shortcutCaptureDeinitRestoresItsPreviousBinding() {
        let action = ShortcutAction.mode(UUID())
        let originalShortcut = Shortcut.key(keyCode: UInt16(kVK_F17), modifierFlags: [])
        ShortcutStore.restorePersistenceState(.stored(originalShortcut), for: action)
        defer { ShortcutStore.removeShortcutStorage(for: action) }

        var recorder: ShortcutRecorderModel? = ShortcutRecorderModel()
        recorder?.start(
            action: action,
            onCapture: { _ in },
            onStoredShortcutChanged: {}
        )
        #expect(ShortcutStore.persistenceState(for: action) == .cleared)

        recorder = nil
        #expect(ShortcutStore.shortcut(for: action) == originalShortcut)
    }

    @Test func cancelShortcutBackupDistinguishesDefaultFromLegacyAbsence() throws {
        let customShortcut = Shortcut.key(
            keyCode: UInt16(kVK_ANSI_X),
            modifierFlags: [.control, .option]
        )
        let decodedDefault = try JSONDecoder().decode(
            GeneralBackup.self,
            from: Data(#"{"cancelRecorderShortcutUsesDefault":true}"#.utf8)
        )

        #expect(
            BackupImporter.cancelRecorderShortcutPersistenceState(
                usesDefault: decodedDefault.cancelRecorderShortcutUsesDefault,
                shortcut: decodedDefault.cancelRecorderShortcut
            ) == .cleared
        )
        #expect(
            BackupImporter.cancelRecorderShortcutPersistenceState(
                usesDefault: false,
                shortcut: ShortcutBackup(customShortcut)
            ) == .stored(customShortcut)
        )
        #expect(
            BackupImporter.cancelRecorderShortcutPersistenceState(
                usesDefault: nil,
                shortcut: nil
            ) == nil
        )
    }

    @Test func recorderWindowsReuseStableDisplaySetAndRebuildOnChange() {
        #expect(RecorderDisplayReusePolicy.shouldReuse(
            existingDisplayIDs: [1, 2, 3],
            currentDisplayIDs: [1, 2, 3]
        ))
        #expect(!RecorderDisplayReusePolicy.shouldReuse(
            existingDisplayIDs: [],
            currentDisplayIDs: [1, 2, 3]
        ))
        #expect(!RecorderDisplayReusePolicy.shouldReuse(
            existingDisplayIDs: [1, 2, 3],
            currentDisplayIDs: [1, 3]
        ))
        #expect(!RecorderDisplayReusePolicy.shouldReuse(
            existingDisplayIDs: [1, 2, 3],
            currentDisplayIDs: [2, 1, 3]
        ))
    }

    @Test func openAILiveTranscribeUsesAccuracyContextAndStructuredHints() throws {
        let realtimeURL = OpenAITranscriptionConfiguration.realtimeWebSocketURL
        let queryItems = URLComponents(url: realtimeURL, resolvingAgainstBaseURL: false)?.queryItems
        #expect(queryItems == [URLQueryItem(name: "intent", value: "transcription")])
        #expect(realtimeURL.absoluteString.contains("gpt-live-transcribe") == false)

        let update = OpenAITranscriptionConfiguration.realtimeSessionUpdate(
            language: "en",
            prompt: "Technical dictation about macOS applications.",
            customVocabulary: ["VoiceInk++", "Codex", "codex", "bad<term>", "line\nbreak"]
        )
        let session = try #require(update["session"] as? [String: Any])
        #expect(session["type"] as? String == "transcription")
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let format = try #require(input["format"] as? [String: Any])
        let transcription = try #require(input["transcription"] as? [String: Any])

        #expect(format["type"] as? String == "audio/pcm")
        #expect(format["rate"] as? Int == 24_000)
        #expect(input["turn_detection"] is NSNull)
        #expect(transcription["model"] as? String == "gpt-live-transcribe")
        #expect(transcription["delay"] as? String == "xhigh")
        #expect(transcription["prompt"] as? String == "Technical dictation about macOS applications.")
        #expect(transcription["languages"] as? [String] == ["en"])
        #expect(transcription["keywords"] as? [String] == ["VoiceInk++", "Codex"])

        let fields = OpenAITranscriptionConfiguration.completedAudioFields(
            language: "en",
            prompt: "Technical dictation about macOS applications.",
            customVocabulary: ["VoiceInk++", "Codex"]
        )
        #expect(fields.contains { $0.name == "model" && $0.value == "gpt-transcribe" })
        #expect(fields.contains { $0.name == "languages[]" && $0.value == "en" })
        #expect(fields.filter { $0.name == "keywords[]" }.map(\.value) == ["VoiceInk++", "Codex"])
        #expect(!fields.contains { $0.name == "language" })
    }

    @Test func openAIRealtimeResamplingIsStableAcrossAudioChunks() {
        let samples = (0..<320).map { index in
            Int16(clamping: (index * 173) - 20_000)
        }
        var source = Data()
        for sample in samples {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { source.append(contentsOf: $0) }
        }

        var singlePass = OpenAIRealtimePCMResampler()
        var expected = singlePass.convert(source)
        expected.append(singlePass.flush())

        var chunked = OpenAIRealtimePCMResampler()
        var actual = Data()
        for range in [0..<137, 137..<401, 401..<source.count] {
            actual.append(chunked.convert(source.subdata(in: range)))
        }
        actual.append(chunked.flush())

        #expect(actual == expected)
        #expect(actual.count == 480 * MemoryLayout<Int16>.size)
    }

    @Test func openAIProviderRegistersLiveTranscribeAsStreamingOnly() {
        let provider = OpenAIProvider()
        #expect(provider.providerKey == "OpenAI")
        #expect(provider.isStreamingOnly)
        #expect(provider.models.count == 1)
        #expect(provider.models.first?.name == "gpt-live-transcribe")
        #expect(provider.models.first?.supportsStreaming == true)
        #expect(
            CloudProviderRegistry.provider(for: .openAI)?.models.contains {
                $0.name == "gpt-live-transcribe"
            } == true
        )
    }

    @Test func assemblyAIUniversal35StreamingUsesMaxAccuracyAndContext() throws {
        let url = try #require(
            AssemblyAIStreamingConnectionConfiguration.connectionURL(
                modelName: AssemblyAIStreamingConnectionConfiguration.universal35ProModelName,
                language: "en",
                prompt: "Technical software dictation.",
                customVocabulary: ["VoiceInk++", "Codex", "codex", "   "]
            )
        )
        let queryItems = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(query["speech_model"] == "universal-3-5-pro")
        #expect(query["mode"] == "max_accuracy")
        #expect(query["language_codes"] == #"["en"]"#)
        #expect(query["prompt"] == "Technical software dictation.")
        #expect(query["keyterms_prompt"] == #"["VoiceInk++","Codex"]"#)
        #expect(query["language_code"] == nil)
        #expect(query["format_turns"] == nil)
    }

    @Test func assemblyAIUniversal35ReplacesLegacyModelNames() {
        #expect(
            StreamingKeysMigration.assemblyAI35ModelMappings["universal-3-pro"]
                == "universal-3-5-pro"
        )
        #expect(
            StreamingKeysMigration.assemblyAI35ModelMappings["u3-rt-pro"]
                == "universal-3-5-pro"
        )

        let provider = AssemblyAIProvider()
        #expect(provider.models.contains { model in
            model.name == "universal-3-5-pro"
                && model.displayName == "Universal-3.5 Pro"
                && model.supportsStreaming
        })
        #expect(!provider.models.contains { $0.name == "universal-3-pro" })
    }

    @Test func configuredCatalogListsEveryModelFromConnectedProviders() {
        let models = CustomProviderManagementView.configuredCloudModels(
            providers: [
                AssemblyAIProvider(),
                SonioxProvider(),
                DeepgramProvider()
            ],
            configuredProviderKeys: ["AssemblyAI", "Soniox"],
            selectedModelNames: ["universal-3-5-pro"]
        )

        #expect(models.first?.name == "universal-3-5-pro")
        #expect(Set(models.map(\.name)) == [
            "universal-3-5-pro",
            "universal-streaming",
            "stt-async-v5"
        ])
        #expect(!models.contains { $0.provider == .deepgram })
    }

    @Test func primaryModifierChordSuppressesOnlyTheCompletedPress() {
        let shortcut = Shortcut.modifierOnly(
            keyCode: nil,
            modifierFlags: [.shift, .control, .option]
        )

        let partialShift = ShortcutMonitor.modifierOnlySequenceTransition(
            shortcut: shortcut,
            wasDown: false,
            keyCode: UInt16(kVK_Shift),
            modifierFlags: [.shift]
        )
        #expect(partialShift == .init(
            isDown: false,
            suppressDownstream: false,
            dispatchKeyDown: false,
            dispatchKeyUp: false
        ))

        let partialControl = ShortcutMonitor.modifierOnlySequenceTransition(
            shortcut: shortcut,
            wasDown: false,
            keyCode: UInt16(kVK_Control),
            modifierFlags: [.shift, .control]
        )
        #expect(partialControl == .init(
            isDown: false,
            suppressDownstream: false,
            dispatchKeyDown: false,
            dispatchKeyUp: false
        ))

        let completedPress = ShortcutMonitor.modifierOnlySequenceTransition(
            shortcut: shortcut,
            wasDown: false,
            keyCode: UInt16(kVK_Option),
            modifierFlags: [.shift, .control, .option]
        )
        #expect(completedPress == .init(
            isDown: true,
            suppressDownstream: true,
            dispatchKeyDown: true,
            dispatchKeyUp: false
        ))

        let completedRepeat = ShortcutMonitor.modifierOnlySequenceTransition(
            shortcut: shortcut,
            wasDown: true,
            keyCode: UInt16(kVK_Option),
            modifierFlags: [.shift, .control, .option]
        )
        #expect(completedRepeat == .init(
            isDown: true,
            suppressDownstream: true,
            dispatchKeyDown: false,
            dispatchKeyUp: false
        ))

        let firstRelease = ShortcutMonitor.modifierOnlySequenceTransition(
            shortcut: shortcut,
            wasDown: true,
            keyCode: UInt16(kVK_Option),
            modifierFlags: [.shift, .control]
        )
        #expect(firstRelease == .init(
            isDown: false,
            suppressDownstream: false,
            dispatchKeyDown: false,
            dispatchKeyUp: true
        ))

        let remainingRelease = ShortcutMonitor.modifierOnlySequenceTransition(
            shortcut: shortcut,
            wasDown: false,
            keyCode: UInt16(kVK_Control),
            modifierFlags: [.shift]
        )
        #expect(remainingRelease == .init(
            isDown: false,
            suppressDownstream: false,
            dispatchKeyDown: false,
            dispatchKeyUp: false
        ))
    }

    @Test func primaryModifierChordExposesOnlyForwardedPartialProgressForCapture() {
        let shortcut = Shortcut.modifierOnly(
            keyCode: nil,
            modifierFlags: [.shift, .control, .option]
        )

        #expect(ShortcutMonitor.isPartialModifierOnlySequence(
            shortcut: shortcut,
            wasDown: false,
            keyCode: UInt16(kVK_Shift),
            modifierFlags: [.shift]
        ))
        #expect(ShortcutMonitor.isPartialModifierOnlySequence(
            shortcut: shortcut,
            wasDown: false,
            keyCode: UInt16(kVK_Control),
            modifierFlags: [.shift, .control]
        ))
        #expect(!ShortcutMonitor.isPartialModifierOnlySequence(
            shortcut: shortcut,
            wasDown: false,
            keyCode: UInt16(kVK_Option),
            modifierFlags: [.shift, .control, .option]
        ))
        #expect(!ShortcutMonitor.isPartialModifierOnlySequence(
            shortcut: shortcut,
            wasDown: true,
            keyCode: UInt16(kVK_Control),
            modifierFlags: [.shift, .control]
        ))
    }

    @Test func openAINoCaretRecordingStartFocusIsPinnedBoundedAndOneShot() throws {
        let source = try repositorySource(
            "VoiceInk/Modes/FocusLockService.swift"
        )
        let start = try #require(source.range(
            of: "    private func focusAuditedOpenAIComposerAtRecordingStart("
        ))
        let end = try #require(source.range(
            of: "    func captureFocusedInput(allowApplicationFallback:",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])

        #expect(body.contains(
            "matchesAuditedOpenAIRetainedPreparationBuild"
        ))
        #expect(body.contains("candidates.count == 1"))
        #expect(body.contains("CFEqual(currentFocus.element, fallbackContainer)"))
        #expect(body.contains("exactStructureMatches"))
        #expect(body.components(
            separatedBy: "AXUIElementSetAttributeValue("
        ).count - 1 == 1)
        #expect(!body.contains(".activate("))
        #expect(!body.contains("kAXFocusedWindowAttribute as CFString"))
        #expect(!body.contains("kAXFocusedUIElementAttribute as CFString"))
    }

    @Test func primaryDoublePressDefersStopThenTogglesPause() {
        var coordinator = PrimaryRecordingPressCoordinator(
            doublePressInterval: 0.5
        )

        let firstDecision = coordinator.registerPress(
            recordingState: .recording,
            eventTime: 10
        )
        #expect(firstDecision == .deferNormalStop(generation: 1))
        #expect(coordinator.hasPendingNormalStop)

        let secondDecision = coordinator.registerPress(
            recordingState: .recording,
            eventTime: 10.3
        )
        #expect(secondDecision == .togglePause)
        #expect(!coordinator.hasPendingNormalStop)
    }

    @Test func genuinePrimaryTriplePressFinishesToClipboard() {
        var coordinator = PrimaryRecordingPressCoordinator(
            doublePressInterval: 0.5
        )

        #expect(coordinator.registerPress(
            recordingState: .recording,
            eventTime: 10
        ) == .deferNormalStop(generation: 1))
        #expect(coordinator.registerPress(
            recordingState: .recording,
            eventTime: 10.2
        ) == .togglePause)
        #expect(coordinator.registerPress(
            recordingState: .paused,
            eventTime: 10.4
        ) == .finishToClipboard)

        // A fourth press/bounce inside the same multi-click window must not start
        // a new recording after the clipboard-only finalization begins.
        #expect(coordinator.registerPress(
            recordingState: .idle,
            eventTime: 10.45
        ) == .ignoreCompletedGesture)
    }

    @Test func separatePrimaryDoublePressesNeverBecomeTriplePress() {
        var coordinator = PrimaryRecordingPressCoordinator(
            doublePressInterval: 0.5
        )

        #expect(coordinator.registerPress(
            recordingState: .recording,
            eventTime: 20
        ) == .deferNormalStop(generation: 1))
        #expect(coordinator.registerPress(
            recordingState: .recording,
            eventTime: 20.2
        ) == .togglePause)

        // The gap ends the first macOS-bounded gesture. This is click one of a
        // fresh double-click, not click three of the earlier one.
        #expect(coordinator.registerPress(
            recordingState: .paused,
            eventTime: 21
        ) == .deferNormalStop(generation: 2))
        #expect(coordinator.registerPress(
            recordingState: .paused,
            eventTime: 21.2
        ) == .togglePause)
    }

    @Test func canceledTranscriptionRecoveryPrefersFinishedTextThenHUDPartial() {
        #expect(TranscriptionCancellationRecovery.resolve([
            "  finished provider text  ",
            "older HUD partial"
        ]) == .recover("finished provider text"))
        #expect(TranscriptionCancellationRecovery.resolve([
            nil,
            "  HUD partial survives  "
        ]) == .recover("HUD partial survives"))
        #expect(TranscriptionCancellationRecovery.resolve([
            nil,
            "  \n "
        ]) == .noResult)
    }

    @Test func canceledTranscriptionStatusDistinguishesRetainedAndEmptyResults() {
        let retained = Transcription(
            text: "",
            duration: 0,
            realtimeDraftText: "  HUD draft  "
        )
        retained.markAsCanceledTranscription(
            preservingRecoveredText: "recover me"
        )
        #expect(retained.text == "recover me")
        #expect(retained.transcriptionStatus ==
            TranscriptionStatus.canceledWithResult.rawValue)
        #expect(retained.recoverableRealtimeDraftText == "HUD draft")

        let empty = Transcription(text: "", duration: 0)
        empty.markAsCanceledTranscription()
        #expect(empty.text == Transcription.canceledTranscriptionText)
        #expect(empty.transcriptionStatus == TranscriptionStatus.canceled.rawValue)
    }

    @Test func realtimeDraftProvidesHistoryRecoveryUntilFinalTextExists() {
        let draft = Transcription(
            text: "",
            duration: 4.2,
            audioFileURL: URL(fileURLWithPath: "/tmp/recoverable.wav").absoluteString,
            realtimeDraftText: "  words already visible in the HUD  ",
            preservesOriginalAudioForRecovery: true,
            transcriptionStatus: .recoverableDraft
        )

        #expect(draft.recoverableRealtimeDraftText == "words already visible in the HUD")
        #expect(draft.historyDisplayText == "words already visible in the HUD")
        #expect(draft.transcriptionStatus == TranscriptionStatus.recoverableDraft.rawValue)
        #expect(draft.audioFileURL?.hasSuffix("recoverable.wav") == true)
        #expect(draft.preservesOriginalAudioForRecovery)

        draft.text = "provider-final text"
        draft.transcriptionStatus = TranscriptionStatus.completed.rawValue
        #expect(draft.historyDisplayText == "provider-final text")
        #expect(draft.recoverableRealtimeDraftText == "words already visible in the HUD")
    }

    @Test func stoppedRecordingPersistsRealtimeDraftBeforePipelineEnqueue() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/VoiceInkEngine.swift"
            ),
            encoding: .utf8
        )
        let snapshot = try #require(source.range(
            of: "active.recoverablePartialTranscript = active.partialTranscript"
        ))
        let enqueue = try #require(source.range(
            of: "enqueueTranscription(for: active, transcription: transcription)",
            range: snapshot.upperBound..<source.endIndex
        ))
        let stopBody = source[snapshot.lowerBound..<enqueue.upperBound]

        #expect(stopBody.contains(
            "realtimeDraftText: active.recoverablePartialTranscript"
        ))
        #expect(stopBody.contains(
            "preservesOriginalAudioForRecovery: completionDisposition == .clipboardOnly"
        ))
        #expect(stopBody.contains(".recoverableDraft"))
        #expect(stopBody.contains("try modelContext.save()"))

        let cancelSnapshot = try #require(source.range(
            of: "session.recoverablePartialTranscript = session.partialTranscript"
        ))
        let canceledPersistence = try #require(source.range(
            of: "await finishCanceledRecording(session)",
            range: cancelSnapshot.upperBound..<source.endIndex
        ))
        #expect(cancelSnapshot.lowerBound < canceledPersistence.lowerBound)
    }

    @Test func clipboardOnlyCompletionReturnsBeforeAnyPasteTargetResolution() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/TranscriptionPipeline.swift"
            ),
            encoding: .utf8
        )
        let clipboardBranch = try #require(source.range(
            of: "        if completionDispositionNow == .clipboardOnly {"
        ))
        let pasteTargetResolution = try #require(source.range(
            of: "        let pasteTargetForDelivery = await resolvePasteTarget()",
            range: clipboardBranch.upperBound..<source.endIndex
        ))
        let clipboardBody = source[
            clipboardBranch.lowerBound..<pasteTargetResolution.lowerBound
        ]

        #expect(clipboardBody.contains("ClipboardManager.copyToClipboard"))
        #expect(clipboardBody.contains("paste=false autoSend=false"))
        #expect(!clipboardBody.contains("delivery.deliver"))
        #expect(!clipboardBody.contains("resolvePasteTarget"))

        // `.respond` enhancement begins earlier than final delivery. Clipboard-only
        // must suppress it there so the copied result remains the transcription.
        #expect(source.contains(
            "completionDispositionNow == .clipboardOnly &&\n" +
            "                    outputForThisDelivery.outputMode == .respond"
        ))
        #expect(source.contains(
            "if !skipPostProcessingNow,\n" +
            "                   !suppressesModeResponse,"
        ))
    }

    @Test func triplePressStopPreservesPlaybackAndUsesNoCancelPath() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shortcutSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Shortcuts/RecordingShortcutManager.swift"
            ),
            encoding: .utf8
        )
        let tripleStart = try #require(shortcutSource.range(
            of: "        case .finishToClipboard:"
        ))
        let nextCase = try #require(shortcutSource.range(
            of: "        case .ignoreCompletedGesture:",
            range: tripleStart.upperBound..<shortcutSource.endIndex
        ))
        let tripleBody = shortcutSource[
            tripleStart.lowerBound..<nextCase.lowerBound
        ]
        #expect(tripleBody.contains("finishRecordingToClipboard(modeId)"))
        #expect(!tripleBody.contains("cancelRecording"))
        #expect(!tripleBody.contains("toggleRecorderPanel"))

        let recorderSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("VoiceInk/Recorder.swift"),
            encoding: .utf8
        )
        #expect(recorderSource.contains(
            "playbackController.abandonPausedMediaOwnership()"
        ))
        #expect(recorderSource.contains(
            "RecordingActivityNotifier.postRecordingStoppedPreservingPlayback()"
        ))
    }

    @Test func primaryPauseDoublePressWindowCapsSlowSystemPreference() {
        #expect(
            PrimaryRecordingPressCoordinator.pauseDoublePressInterval(
                systemDoubleClickInterval: 0.8
            ) == 0.45
        )
        #expect(
            PrimaryRecordingPressCoordinator.pauseDoublePressInterval(
                systemDoubleClickInterval: 0.3
            ) == 0.3
        )
        #expect(
            PrimaryRecordingPressCoordinator.triplePressContinuationInterval(
                systemDoubleClickInterval: 0.8
            ) == 0.8
        )
    }

    @Test func thirdPrimaryPressUsesSystemIntervalWithoutDelayingNormalStop() {
        var coordinator = PrimaryRecordingPressCoordinator(
            normalStopDecisionInterval: 0.45,
            triplePressContinuationInterval: 0.8
        )

        #expect(coordinator.registerPress(
            recordingState: .recording,
            eventTime: 10
        ) == .deferNormalStop(generation: 1))
        #expect(coordinator.registerPress(
            recordingState: .recording,
            eventTime: 10.3
        ) == .togglePause)
        // 0.6s after click two would have failed under the old 0.45s reuse,
        // but is one genuine continuation under Ethan's 0.8s macOS setting.
        #expect(coordinator.registerPress(
            recordingState: .paused,
            eventTime: 10.9
        ) == .finishToClipboard)

        var slowFirstPair = PrimaryRecordingPressCoordinator(
            normalStopDecisionInterval: 0.45,
            triplePressContinuationInterval: 0.8
        )
        #expect(slowFirstPair.registerPress(
            recordingState: .recording,
            eventTime: 20
        ) == .deferNormalStop(generation: 1))
        #expect(slowFirstPair.registerPress(
            recordingState: .recording,
            eventTime: 20.6
        ) == .performOverdueNormalStop)

        var separateGesture = PrimaryRecordingPressCoordinator(
            normalStopDecisionInterval: 0.45,
            triplePressContinuationInterval: 0.8
        )
        #expect(separateGesture.registerPress(
            recordingState: .recording,
            eventTime: 30
        ) == .deferNormalStop(generation: 1))
        #expect(separateGesture.registerPress(
            recordingState: .recording,
            eventTime: 30.2
        ) == .togglePause)
        #expect(separateGesture.registerPress(
            recordingState: .paused,
            eventTime: 31.01
        ) == .deferNormalStop(generation: 2))
    }

    @Test func errorNotificationClearsExpandedRealtimeMiniRecorder() {
        let reservedHeight = MiniRecorderLayoutMetrics.notificationBottomReservedHeight(
            showsAssistant: false,
            showsRealtimeTranscript: true,
            sessionCount: 1
        )
        let recorderTop = reservedHeight
        let origin = NotificationManager.notificationOrigin(
            screenRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            notificationSize: NSSize(width: 500, height: 44),
            bottomReservedHeight: reservedHeight
        )

        #expect(reservedHeight == 121)
        #expect(origin.y == recorderTop + 16)
    }

    @Test func errorNotificationAlsoClearsStackedMiniRecorderCards() {
        let reservedHeight = MiniRecorderLayoutMetrics.notificationBottomReservedHeight(
            showsAssistant: false,
            showsRealtimeTranscript: true,
            sessionCount: 3
        )
        #expect(reservedHeight == 213)
    }

    @Test func primaryDoublePressWhilePausedResumesInsteadOfStopping() {
        var coordinator = PrimaryRecordingPressCoordinator(
            doublePressInterval: 0.5
        )

        let firstDecision = coordinator.registerPress(
            recordingState: .paused,
            eventTime: 20
        )
        #expect(firstDecision == .deferNormalStop(generation: 1))
        let secondDecision = coordinator.registerPress(
            recordingState: .paused,
            eventTime: 20.4
        )
        #expect(secondDecision == .togglePause)
    }

    @Test func primarySinglePressCommitsExactlyOneDeferredStop() {
        var coordinator = PrimaryRecordingPressCoordinator(
            doublePressInterval: 0.5
        )
        let decision = coordinator.registerPress(
            recordingState: .recording,
            eventTime: 30
        )
        let generation: Int
        switch decision {
        case .deferNormalStop(let value):
            generation = value
        default:
            Issue.record("Expected a deferred Primary normal stop")
            return
        }

        let firstConsumption = coordinator.consumeDeferredStop(
            generation: generation
        )
        let secondConsumption = coordinator.consumeDeferredStop(
            generation: generation
        )
        #expect(firstConsumption)
        #expect(!secondConsumption)
        #expect(!coordinator.hasPendingNormalStop)
    }

    @Test func alternateStopCanCancelPendingPrimaryDecision() {
        var coordinator = PrimaryRecordingPressCoordinator(
            doublePressInterval: 0.5
        )
        let decision = coordinator.registerPress(
            recordingState: .recording,
            eventTime: 40
        )
        let generation: Int
        switch decision {
        case .deferNormalStop(let value):
            generation = value
        default:
            Issue.record("Expected a deferred Primary normal stop")
            return
        }

        coordinator.cancelPendingStop()
        #expect(!coordinator.hasPendingNormalStop)
        let consumedAfterCancellation = coordinator.consumeDeferredStop(
            generation: generation
        )
        #expect(!consumedAfterCancellation)
    }

    @MainActor
    @Test func rapidSecondPrimaryToggleBypassesOnlyLegacyCooldown() {
        #expect(!RecordingShortcutModeHandler.shouldApplyShortcutPressCooldown(
            action: .primaryRecording,
            mode: .toggle
        ))
        #expect(RecordingShortcutModeHandler.shouldApplyShortcutPressCooldown(
            action: .secondaryRecording,
            mode: .toggle
        ))
        #expect(RecordingShortcutModeHandler.shouldApplyShortcutPressCooldown(
            action: .primaryRecording,
            mode: .pushToTalk
        ))
    }

    @Test func pausedCoreAudioRejectsEveryInputBuffer() {
        #expect(CoreAudioRecorder.shouldProcessInputBuffer(
            isRecording: true,
            isPaused: false
        ))
        #expect(!CoreAudioRecorder.shouldProcessInputBuffer(
            isRecording: true,
            isPaused: true
        ))
        #expect(!CoreAudioRecorder.shouldProcessInputBuffer(
            isRecording: false,
            isPaused: false
        ))
    }

    @Test func capturePauseResumeNeverControlsPlaybackOrYouTubeHelper() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("VoiceInk/Recorder.swift"),
            encoding: .utf8
        )
        let pauseStart = try #require(source.range(
            of: "    func pauseRecording() async throws {"
        ))
        let resumeStart = try #require(source.range(
            of: "    func resumeRecording() async throws {",
            range: pauseStart.upperBound..<source.endIndex
        ))
        let stopStart = try #require(source.range(
            of: "    func stopRecording(\n",
            range: resumeStart.upperBound..<source.endIndex
        ))
        let pauseBody = source[pauseStart.lowerBound..<resumeStart.lowerBound]
        let resumeBody = source[resumeStart.lowerBound..<stopStart.lowerBound]
        let startBody = source[source.startIndex..<pauseStart.lowerBound]
        let stopBody = source[stopStart.lowerBound..<source.endIndex]
        let pauseSuccessStart = try #require(pauseBody.range(
            of: "        resetAudioMeter()"
        ))
        let pauseSuccessBody = pauseBody[pauseSuccessStart.lowerBound..<pauseBody.endIndex]

        // Pausing may lift VoiceInk++'s system-output mute so Ethan can hear media
        // he starts himself. Resuming may restore that mute. Neither transition
        // owns playback or the external YouTube-helper recording lifecycle. A
        // failed hardware pause may reassert the initial recording suppression,
        // so the no-pauseMedia guard begins only after pause succeeds.
        #expect(pauseBody.contains("mediaController.unmuteSystemAudio()"))
        #expect(resumeBody.contains("muteSystemAudio()"))
        #expect(!pauseBody.contains("playbackController."))
        #expect(!resumeBody.contains("playbackController."))
        #expect(!pauseSuccessBody.contains("pauseMedia()"))
        #expect(!resumeBody.contains("pauseMedia()"))
        #expect(!pauseBody.contains("RecordingActivityNotifier."))
        #expect(!resumeBody.contains("RecordingActivityNotifier."))

        // Normal recording start/final stop remain the sole paired boundaries.
        #expect(startBody.contains("pauseMedia()"))
        #expect(startBody.contains("RecordingActivityNotifier.postRecordingStarted()"))
        #expect(stopBody.contains("playbackController.resumeMedia()"))
        #expect(stopBody.contains("RecordingActivityNotifier.postRecordingStopped()"))
    }

    @Test func nextTrackCancelsDeferredPrimaryStopBeforeItsOwnRoute() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Shortcuts/RecordingShortcutManager.swift"
            ),
            encoding: .utf8
        )
        let nextStart = try #require(source.range(
            of: "            onNextTrackKeyDown:"
        ))
        let monitorEnd = try #require(source.range(
            of: "        )\n    }\n\n    static func shouldConsumeNextTrack",
            range: nextStart.upperBound..<source.endIndex
        ))
        let nextBody = source[nextStart.lowerBound..<monitorEnd.lowerBound]
        let cancellation = try #require(nextBody.range(
            of: "cancelPendingPrimaryStopDecision()"
        ))
        let recordingStartRoute = try #require(nextBody.range(
            of: "stopPasteDestination: .recordingStart"
        ))

        #expect(cancellation.lowerBound < recordingStartRoute.lowerBound)

        let deferredStart = try #require(source.range(
            of: "    private func schedulePrimaryNormalStop("
        ))
        let deferredEnd = try #require(source.range(
            of: "    func cancelPendingPrimaryStopDecision()",
            range: deferredStart.upperBound..<source.endIndex
        ))
        let deferredBody = source[
            deferredStart.lowerBound..<deferredEnd.lowerBound
        ]
        #expect(deferredBody.contains(
            "toggleRecorderPanel(modeId, .primaryCurrentInput)"
        ))
        #expect(!deferredBody.contains(".recordingStart"))
        #expect(!deferredBody.contains(".focusedDuringTranscription"))
    }

    @Test func recordingStartReservationRejectsDuplicatePendingStarts() {
        var reservation = RecordingStartReservation()
        let first = UUID()
        let second = UUID()

        #expect(reservation.reserve(id: first) == first)
        #expect(reservation.reserve(id: second) == nil)
        let consumedWrongReservation = reservation.consume(second)
        #expect(!consumedWrongReservation)
        let consumedFirstReservation = reservation.consume(first)
        #expect(consumedFirstReservation)
        #expect(reservation.reserve(id: second) == second)

        reservation.invalidate()
        #expect(reservation.pendingID == nil)
    }

    @MainActor
    @Test func activeRecordingBarrierDefersOlderDeliveryThroughReservationAndCapture() async {
        let barrier = ActiveRecordingDeliveryBarrier()
        let reservationID = UUID()
        let recordingSessionID = UUID()
        let deliveryID = UUID()
        let state = TranscriptionQueueTestState()

        barrier.beginCapture(owner: reservationID)
        let waiter = Task { @MainActor in
            let acquired = await barrier.acquireDelivery(
                owner: deliveryID
            ) { true }
            state.events.append("acquired:\(acquired)")
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(state.events.isEmpty)

        // Turning the pending start into the actual session is atomic: it must not
        // create an unblocked instant in which the older result can paste.
        barrier.transferCapture(from: reservationID, to: recordingSessionID)
        for _ in 0..<20 { await Task.yield() }
        #expect(state.events.isEmpty)
        #expect(barrier.activeCaptureOwners == [recordingSessionID])

        barrier.endCapture(owner: recordingSessionID)
        await waiter.value
        #expect(state.events == ["acquired:true"])
        #expect(!barrier.isDeliveryBlocked)
        #expect(barrier.activeDeliveryOwners == [deliveryID])
        barrier.releaseDelivery(owner: deliveryID)
    }

    @MainActor
    @Test func primaryPasteLeaseCrossesActiveCaptureWhileExclusiveWorkStillWaits() async {
        let barrier = ActiveRecordingDeliveryBarrier()
        let activeRecordingID = UUID()
        let primaryDeliveryID = UUID()
        let exactDeliveryID = UUID()
        let state = TranscriptionQueueTestState()

        barrier.beginCapture(owner: activeRecordingID)
        let primaryAcquired = await barrier.acquireDelivery(
            owner: primaryDeliveryID,
            policy: .primaryPasteDuringCapture
        ) { true }
        #expect(primaryAcquired)
        #expect(barrier.activeCaptureOwners == [activeRecordingID])
        #expect(barrier.activeDeliveryOwners == [primaryDeliveryID])

        let exactWaiter = Task { @MainActor in
            let acquired = await barrier.acquireDelivery(
                owner: exactDeliveryID,
                policy: .exclusive
            ) { true }
            state.events.append("exact:\(acquired)")
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(state.events.isEmpty)

        barrier.releaseDelivery(owner: primaryDeliveryID)
        for _ in 0..<20 { await Task.yield() }
        #expect(state.events.isEmpty)

        barrier.endCapture(owner: activeRecordingID)
        await exactWaiter.value
        #expect(state.events == ["exact:true"])
        barrier.releaseDelivery(owner: exactDeliveryID)
    }

    @MainActor
    @Test func deliveryLeaseMakesANewerCaptureHandshakeWaitWithoutLosingItsReservation() async {
        let barrier = ActiveRecordingDeliveryBarrier()
        let deliveryID = UUID()
        let reservationID = UUID()
        let state = TranscriptionQueueTestState()

        let deliveryAcquired = await barrier.acquireDelivery(owner: deliveryID) { true }
        #expect(deliveryAcquired)
        barrier.beginCapture(owner: reservationID)
        #expect(barrier.hasCaptureWaitingBehindDelivery)
        let startWaiter = Task { @MainActor in
            let canStart = await barrier.waitUntilCaptureMayStart { true }
            state.events.append("start:\(canStart)")
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(state.events.isEmpty)
        #expect(barrier.activeCaptureOwners == [reservationID])
        #expect(barrier.activeDeliveryOwners == [deliveryID])

        barrier.releaseDelivery(owner: deliveryID)
        await startWaiter.value
        #expect(state.events == ["start:true"])
        #expect(barrier.activeCaptureOwners == [reservationID])
        #expect(!barrier.hasCaptureWaitingBehindDelivery)
        barrier.endCapture(owner: reservationID)
    }

    @MainActor
    @Test func canceledOlderJobCanLeaveBarrierWithoutEndingNewerRecording() async {
        let barrier = ActiveRecordingDeliveryBarrier()
        let activeRecordingID = UUID()
        let state = TranscriptionQueueTestState()
        var shouldContinueWaiting = true

        barrier.beginCapture(owner: activeRecordingID)
        let waiter = Task { @MainActor in
            let acquired = await barrier.acquireDelivery(
                owner: UUID()
            ) {
                shouldContinueWaiting
            }
            state.events.append("canceled:\(acquired)")
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(state.events.isEmpty)

        shouldContinueWaiting = false
        barrier.notifyStateChange()
        await waiter.value
        #expect(state.events == ["canceled:false"])
        #expect(barrier.isDeliveryBlocked)
        #expect(barrier.activeCaptureOwners == [activeRecordingID])

        barrier.endCapture(owner: activeRecordingID)
    }

    @MainActor
    @Test func resetWakesADeferredDeliveryAndInvalidatesItsRealJobPredicate() async throws {
        let barrier = ActiveRecordingDeliveryBarrier()
        var registry = TranscriptionJobRegistry()
        let activeRecordingID = UUID()
        let registeredIdentity = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/deferred-reset.wav")
        )
        let identity = try #require(registeredIdentity)

        barrier.beginCapture(owner: activeRecordingID)
        let waiter = Task { @MainActor in
            await barrier.acquireDelivery(owner: identity.transcriptionID) {
                registry.contains(identity)
            }
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(barrier.isDeliveryBlocked)

        registry.invalidateAll()
        barrier.reset()

        let acquiredAfterReset = await waiter.value
        #expect(acquiredAfterReset == false)
        #expect(barrier.activeCaptureOwners.isEmpty)
        #expect(barrier.activeDeliveryOwners.isEmpty)
    }

    @MainActor
    @Test func resetCancelsADeferredStartReservationWithoutStartingCapture() async throws {
        let barrier = ActiveRecordingDeliveryBarrier()
        var reservation = RecordingStartReservation()
        let reservedRequestID = reservation.reserve()
        let requestID = try #require(reservedRequestID)
        let deliveryID = UUID()
        var isResetting = false

        let deliveryAcquired = await barrier.acquireDelivery(
            owner: deliveryID
        ) { true }
        #expect(deliveryAcquired)
        barrier.beginCapture(owner: requestID)
        let waiter = Task { @MainActor in
            await barrier.waitUntilCaptureMayStart {
                reservation.pendingID == requestID && !isResetting
            }
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(barrier.isCaptureStartBlocked)

        isResetting = true
        reservation.invalidate()
        barrier.reset()

        let startedAfterReset = await waiter.value
        #expect(startedAfterReset == false)
        #expect(reservation.pendingID == nil)
        #expect(barrier.activeCaptureOwners.isEmpty)
        #expect(barrier.activeDeliveryOwners.isEmpty)
    }

    @MainActor
    @Test func captureTransferFailsClosedWithoutItsReservationOwner() {
        let barrier = ActiveRecordingDeliveryBarrier()
        let unrelatedOwner = UUID()
        let missingReservation = UUID()
        let sessionID = UUID()

        barrier.beginCapture(owner: unrelatedOwner)

        #expect(!barrier.transferCapture(
            from: missingReservation,
            to: sessionID
        ))
        #expect(barrier.activeCaptureOwners == [unrelatedOwner])
        #expect(!barrier.activeCaptureOwners.contains(sessionID))
    }

    @Test func primaryNextAndMidStartCancellationShareCaptureReleaseContract() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let engineSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/VoiceInkEngine.swift"
            ),
            encoding: .utf8
        )
        let shortcutSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Shortcuts/RecordingShortcutManager.swift"
            ),
            encoding: .utf8
        )

        let midStartCancel = try #require(engineSource.range(
            of: "if let active = activeRecordingSession, active.liveRecordingState == .starting"
        ))
        let commonStop = try #require(engineSource.range(
            of: "if let active = activeRecordingSession {",
            range: midStartCancel.upperBound..<engineSource.endIndex
        ))
        let commonRelease = try #require(engineSource.range(
            of: "activeRecordingDeliveryBarrier.endCapture(owner: active.id)",
            range: commonStop.upperBound..<engineSource.endIndex
        ))
        let commonQueueDrain = try #require(engineSource.range(
            of: "reportUnresolvedPrimaryAutoSendIfQueueDrained()",
            range: commonRelease.upperBound..<engineSource.endIndex
        ))
        let routeSwitch = try #require(engineSource.range(
            of: "switch stopPasteDestination",
            range: commonQueueDrain.upperBound..<engineSource.endIndex
        ))
        let enqueue = try #require(engineSource.range(
            of: "enqueueTranscription(for: active, transcription: transcription)",
            range: routeSwitch.upperBound..<engineSource.endIndex
        ))
        let startBranch = try #require(engineSource.range(
            of: "// ── START branch",
            range: enqueue.upperBound..<engineSource.endIndex
        ))
        let cancelRecordingCase = try #require(engineSource.range(
            of: "case .recording:",
            range: startBranch.upperBound..<engineSource.endIndex
        ))
        let delegatedRelease = try #require(engineSource.range(
            of: "activeRecordingDeliveryBarrier.endCapture(owner: session.id)",
            range: cancelRecordingCase.upperBound..<engineSource.endIndex
        ))

        #expect(commonStop.lowerBound < commonRelease.lowerBound)
        #expect(commonRelease.lowerBound < commonQueueDrain.lowerBound)
        #expect(commonQueueDrain.lowerBound < routeSwitch.lowerBound)
        #expect(routeSwitch.lowerBound < enqueue.lowerBound)
        #expect(enqueue.lowerBound < startBranch.lowerBound)
        #expect(cancelRecordingCase.lowerBound < delegatedRelease.lowerBound)
        #expect(shortcutSource.contains(
            "stopPasteDestination: .recordingStart"
        ))
    }

    @Test func normalDeliveryLeaseBeginsAfterTargetFreezeAndBeforeSideEffects() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/TranscriptionPipeline.swift"
            ),
            encoding: .utf8
        )
        let clipboardOnly = try #require(source.range(
            of: "if completionDispositionNow == .clipboardOnly"
        ))
        let pasteTarget = try #require(source.range(
            of: "let pasteTargetForDelivery = await resolvePasteTarget()",
            range: clipboardOnly.upperBound..<source.endIndex
        ))
        let leasePolicy = try #require(source.range(
            of: "let deliveryLeasePolicy: TranscriptionDeliveryLeasePolicy =",
            range: pasteTarget.upperBound..<source.endIndex
        ))
        let lease = try #require(source.range(
            of: "guard await acquireDeliveryLease(deliveryLeasePolicy)",
            range: leasePolicy.upperBound..<source.endIndex
        ))
        let delivery = try #require(source.range(
            of: "await delivery.deliver(",
            range: lease.upperBound..<source.endIndex
        ))
        let guardedBody = source[leasePolicy.lowerBound..<delivery.lowerBound]

        #expect(clipboardOnly.lowerBound < pasteTarget.lowerBound)
        #expect(pasteTarget.lowerBound < leasePolicy.lowerBound)
        #expect(leasePolicy.lowerBound < lease.lowerBound)
        #expect(lease.lowerBound < delivery.lowerBound)
        #expect(guardedBody.contains("defer { releaseDeliveryLease() }"))
        #expect(guardedBody.contains("if shouldCancel()"))
        #expect(guardedBody.contains("guard isDeliveryAuthorized()"))
        #expect(guardedBody.contains(".primaryPasteDuringCapture"))
        #expect(guardedBody.contains("pasteTargetForDelivery.destination == .primaryCurrentInput"))
        #expect(guardedBody.contains("outputForPasteTarget.outputMode == .paste"))
    }

    @Test func transcriptionJobRegistryBindsUniqueSessionTranscriptionAndAudio() throws {
        var registry = TranscriptionJobRegistry()
        let sessionA = UUID()
        let transcriptionA = UUID()
        let audioA = URL(fileURLWithPath: "/tmp/session-a.wav")
        let registeredA = registry.register(
            recordingSessionID: sessionA,
            transcriptionID: transcriptionA,
            audioURL: audioA
        )
        let identityA = try #require(registeredA)

        #expect(identityA.enqueueSequence == 1)
        #expect(registry.contains(identityA))
        let duplicateSession = registry.register(
            recordingSessionID: sessionA,
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/other.wav")
        )
        #expect(duplicateSession == nil)
        let duplicateTranscription = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: transcriptionA,
            audioURL: URL(fileURLWithPath: "/tmp/other.wav")
        )
        #expect(duplicateTranscription == nil)
        let duplicateAudio = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: audioA
        )
        #expect(duplicateAudio == nil)

        let registeredB = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/session-b.wav")
        )
        let identityB = try #require(registeredB)
        #expect(identityB.enqueueSequence == 2)
        #expect(identityB.recordingSessionID != identityA.recordingSessionID)
        #expect(identityB.transcriptionID != identityA.transcriptionID)
        #expect(identityB.audioURL != identityA.audioURL)
    }

    @Test func transcriptionJobRegistryResetInvalidatesOnlyOldGeneration() throws {
        var registry = TranscriptionJobRegistry()
        let registeredA = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/session-a.wav")
        )
        let identityA = try #require(registeredA)

        registry.invalidateAll()
        #expect(!registry.contains(identityA))

        let registeredB = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/session-b.wav")
        )
        let identityB = try #require(registeredB)
        #expect(identityB.generation == identityA.generation + 1)
        #expect(identityB.enqueueSequence == identityA.enqueueSequence + 1)
        #expect(registry.contains(identityB))
    }

    @Test func transcriptionJobRegistryReturnsEveryNewerIdentityInFIFOOrder() throws {
        var registry = TranscriptionJobRegistry()
        var identities: [TranscriptionJobIdentity] = []
        for index in 0..<3 {
            let registered = registry.register(
                recordingSessionID: UUID(),
                transcriptionID: UUID(),
                audioURL: URL(fileURLWithPath: "/tmp/primary-queue-\(index).wav")
            )
            identities.append(try #require(registered))
        }

        #expect(registry.newerIdentities(after: identities[0]) == [
            identities[1], identities[2],
        ])
        registry.remove(identities[1])
        #expect(registry.newerIdentities(after: identities[0]) == [
            identities[2],
        ])

        registry.invalidateAll()
        #expect(registry.newerIdentities(after: identities[0]).isEmpty)
        #expect(registry.newerIdentities(after: TranscriptionJobIdentity(
            generation: 999,
            enqueueSequence: 999,
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/not-registered.wav")
        )).isEmpty)
    }

    @Test func twoQueuedPrimaryPastesGiveAutoSendOnlyToTheTail() {
        let first = PrimaryQueuedAutoSendPolicy.resolve(
            originalKey: .enter,
            currentIsEligiblePrimaryPaste: true,
            newerCandidates: [
                PrimaryQueuedAutoSendCandidate(
                    enqueueSequence: 2,
                    isEligiblePrimaryPaste: true
                ),
            ]
        )
        let tail = PrimaryQueuedAutoSendPolicy.resolve(
            originalKey: .enter,
            currentIsEligiblePrimaryPaste: true,
            newerCandidates: []
        )

        #expect(first.originalKey == .enter)
        #expect(first.effectiveKey == .none)
        #expect(first.isSuppressed)
        #expect(first.queuedTailSequence == 2)
        #expect(first.consecutiveSuccessorCount == 1)
        #expect(tail.effectiveKey == .enter)
        #expect(!tail.isSuppressed)
    }

    @Test func aPendingRecordingStartSuppressesTheOlderPrimaryReturn() {
        let resolution = PrimaryQueuedAutoSendPolicy.resolve(
            originalKey: .enter,
            currentIsEligiblePrimaryPaste: true,
            newerCandidates: [],
            newerRecordingStartPending: true
        )

        #expect(resolution.originalKey == .enter)
        #expect(resolution.effectiveKey == .none)
        #expect(resolution.isQueuedSuppression)
        #expect(resolution.suppressionReason == .pendingRecordingStart)
        #expect(resolution.queuedTailSequence == nil)
        #expect(resolution.consecutiveSuccessorCount == 0)
    }

    @MainActor
    @Test func aStartReservedBehindTheOlderDeliveryLeaseCountsAsContinuationIntent() async {
        let barrier = ActiveRecordingDeliveryBarrier()
        let olderDeliveryID = UUID()
        let newerStartID = UUID()
        let trackerSequence: UInt64 = 41
        var tracker = PrimaryQueuedAutoSendTracker()

        #expect(await barrier.acquireDelivery(owner: olderDeliveryID) { true })
        barrier.beginCapture(owner: newerStartID)

        let resolution = PrimaryQueuedAutoSendPolicy.resolve(
            originalKey: .enter,
            currentIsEligiblePrimaryPaste: true,
            newerCandidates: [],
            newerRecordingStartPending:
                barrier.hasCaptureWaitingBehindDelivery
        )
        tracker.observeSuccessfulPrimaryPaste(
            sequence: trackerSequence,
            resolution: resolution
        )

        #expect(resolution.suppressionReason == .pendingRecordingStart)
        #expect(tracker.suppressedSequences == [trackerSequence])
        #expect(tracker.takeUnresolvedIfQueueDrained(
            hasOutstandingSuccessor: barrier.isDeliveryBlocked
        ).isEmpty)

        barrier.releaseDelivery(owner: olderDeliveryID)
        barrier.endCapture(owner: newerStartID)
    }

    @Test func threeQueuedPrimaryPastesGiveAutoSendOnlyToTheNewestTail() {
        let first = PrimaryQueuedAutoSendPolicy.resolve(
            originalKey: .commandEnter,
            currentIsEligiblePrimaryPaste: true,
            newerCandidates: [
                PrimaryQueuedAutoSendCandidate(
                    enqueueSequence: 2,
                    isEligiblePrimaryPaste: true
                ),
                PrimaryQueuedAutoSendCandidate(
                    enqueueSequence: 3,
                    isEligiblePrimaryPaste: true
                ),
            ]
        )
        let second = PrimaryQueuedAutoSendPolicy.resolve(
            originalKey: .shiftEnter,
            currentIsEligiblePrimaryPaste: true,
            newerCandidates: [
                PrimaryQueuedAutoSendCandidate(
                    enqueueSequence: 3,
                    isEligiblePrimaryPaste: true
                ),
            ]
        )
        let third = PrimaryQueuedAutoSendPolicy.resolve(
            originalKey: .commandEnter,
            currentIsEligiblePrimaryPaste: true,
            newerCandidates: []
        )

        #expect(first.effectiveKey == .none)
        #expect(first.queuedTailSequence == 3)
        #expect(first.consecutiveSuccessorCount == 2)
        #expect(second.effectiveKey == .none)
        #expect(second.queuedTailSequence == 3)
        #expect(third.effectiveKey == .commandEnter)
    }

    @Test func registryAndPolicyProduceFIFOAutoSendSequenceForABC() throws {
        var registry = TranscriptionJobRegistry()
        var identities: [TranscriptionJobIdentity] = []
        for index in 0..<3 {
            let registered = registry.register(
                recordingSessionID: UUID(),
                transcriptionID: UUID(),
                audioURL: URL(fileURLWithPath: "/tmp/queue-integration-\(index).wav")
            )
            identities.append(try #require(registered))
        }

        var effectiveKeys: [AutoSendKey] = []
        for identity in identities {
            let successors = registry.newerIdentities(after: identity).map {
                PrimaryQueuedAutoSendCandidate(
                    enqueueSequence: $0.enqueueSequence,
                    isEligiblePrimaryPaste: true
                )
            }
            effectiveKeys.append(PrimaryQueuedAutoSendPolicy.resolve(
                originalKey: .enter,
                currentIsEligiblePrimaryPaste: true,
                newerCandidates: successors
            ).effectiveKey)
            registry.remove(identity)
        }

        #expect(effectiveKeys == [.none, .none, .enter])
        #expect(registry.isEmpty)
    }

    @Test func queuedPrimaryPolicyPreservesSingleAndDisabledAutoSend() {
        let single = PrimaryQueuedAutoSendPolicy.resolve(
            originalKey: .shiftEnter,
            currentIsEligiblePrimaryPaste: true,
            newerCandidates: []
        )
        let disabled = PrimaryQueuedAutoSendPolicy.resolve(
            originalKey: .none,
            currentIsEligiblePrimaryPaste: true,
            newerCandidates: [
                PrimaryQueuedAutoSendCandidate(
                    enqueueSequence: 2,
                    isEligiblePrimaryPaste: true
                ),
            ]
        )

        #expect(single == .unchanged(.shiftEnter))
        #expect(disabled.originalKey == .none)
        #expect(disabled.effectiveKey == .none)
        #expect(!disabled.isSuppressed)
        #expect(disabled.queuedTailSequence == 2)
        #expect(disabled.consecutiveSuccessorCount == 1)
    }

    @Test func unrelatedOrCanceledSuccessorBreaksPrimaryAutoSendCohort() {
        let exactNextOrCanceledSuccessor = PrimaryQueuedAutoSendCandidate(
            enqueueSequence: 2,
            isEligiblePrimaryPaste: false
        )
        let laterPrimary = PrimaryQueuedAutoSendCandidate(
            enqueueSequence: 3,
            isEligiblePrimaryPaste: true
        )
        let resolution = PrimaryQueuedAutoSendPolicy.resolve(
            originalKey: .enter,
            currentIsEligiblePrimaryPaste: true,
            newerCandidates: [exactNextOrCanceledSuccessor, laterPrimary],
            newerRecordingStartPending: true
        )

        // Never skip across a Next route, cancellation, failed/reset lineage,
        // clipboard-only exit, raw mode, response, command, or assistant flow.
        #expect(resolution == .unchanged(.enter))
    }

    @Test func ineligibleCurrentDeliveryCanNeverSuppressItsAutoSend() {
        let resolution = PrimaryQueuedAutoSendPolicy.resolve(
            originalKey: .commandEnter,
            currentIsEligiblePrimaryPaste: false,
            newerCandidates: [
                PrimaryQueuedAutoSendCandidate(
                    enqueueSequence: 2,
                    isEligiblePrimaryPaste: true
                ),
            ]
        )

        #expect(resolution == .unchanged(.commandEnter))
    }

    @Test func queuedPrimaryTrackerClearsWhenALaterPrimaryAutoSendActuallyPosts() {
        var tracker = PrimaryQueuedAutoSendTracker()
        let firstResolution = PrimaryQueuedAutoSendPolicy.resolve(
            originalKey: .enter,
            currentIsEligiblePrimaryPaste: true,
            newerCandidates: [
                PrimaryQueuedAutoSendCandidate(
                    enqueueSequence: 2,
                    isEligiblePrimaryPaste: true
                ),
            ]
        )
        tracker.observeSuccessfulPrimaryPaste(
            sequence: 1,
            resolution: firstResolution
        )
        #expect(tracker.suppressedSequences == [1])
        #expect(tracker.expectedTailSequence == 2)

        // Sequence 2 may cancel or retarget and never reach Primary. If a later
        // Primary sequence 3 successfully posts Return, it is the only evidence that
        // the outstanding queue cohort received a real submission action.
        tracker.observePrimaryAutoSendIssued(sequence: 3)
        #expect(tracker.suppressedSequences.isEmpty)
        #expect(tracker.expectedTailSequence == nil)
    }

    @Test func cancellationDuringPrimaryPasteSettlementSuppressesReturn() {
        let resolution = PrimaryQueuedAutoSendResolution.canceledCurrent(.enter)

        #expect(resolution.originalKey == .enter)
        #expect(resolution.effectiveKey == .none)
        #expect(resolution.isSuppressed)
        #expect(!resolution.isQueuedSuppression)
        #expect(resolution.suppressionReason == .currentCanceled)
        #expect(resolution.queuedTailSequence == nil)
    }

    @Test func queuedPrimaryTrackerSurfacesOrphanOnlyAfterRegistryDrains() {
        var tracker = PrimaryQueuedAutoSendTracker()
        tracker.observeSuccessfulPrimaryPaste(
            sequence: 10,
            resolution: PrimaryQueuedAutoSendResolution(
                originalKey: .commandEnter,
                effectiveKey: .none,
                queuedTailSequence: 12,
                consecutiveSuccessorCount: 2,
                suppressionReason: .queuedSuccessor
            )
        )

        #expect(tracker.takeUnresolvedIfQueueDrained(
            hasOutstandingSuccessor: true
        ).isEmpty)
        #expect(tracker.takeUnresolvedIfQueueDrained(
            hasOutstandingSuccessor: false
        ) == [10])
        #expect(tracker.takeUnresolvedIfQueueDrained(
            hasOutstandingSuccessor: false
        ).isEmpty)
    }

    @Test func primaryQueuePolicyResolvesAtTheLastPrimaryReturnBoundaryOnly() throws {
        let pipelineSource = try repositorySource(
            "VoiceInk/Transcription/Engine/TranscriptionPipeline.swift"
        )
        let deliverySource = try repositorySource(
            "VoiceInk/Transcription/Engine/TranscriptionDelivery.swift"
        )
        let engineSource = try repositorySource(
            "VoiceInk/Transcription/Engine/VoiceInkEngine.swift"
        )
        let lease = try #require(pipelineSource.range(
            of: "guard await acquireDeliveryLease(deliveryLeasePolicy)"
        ))
        let threadedResolver = try #require(pipelineSource.range(
            of: "resolveQueuedPrimaryAutoSend: { key in",
            range: lease.upperBound..<pipelineSource.endIndex
        ))
        let deliver = try #require(pipelineSource.range(
            of: "await delivery.deliver(",
            range: lease.upperBound..<pipelineSource.endIndex
        ))

        #expect(lease.lowerBound < deliver.lowerBound)
        #expect(deliver.lowerBound < threadedResolver.lowerBound)

        let primaryStart = try #require(deliverySource.range(
            of: "    private func deliverPrimaryToCurrentSystemInput("
        ))
        let exactStart = try #require(deliverySource.range(
            of: "    private func deliverToBackgroundExactInput(",
            range: primaryStart.upperBound..<deliverySource.endIndex
        ))
        let primaryBody = deliverySource[
            primaryStart.lowerBound..<exactStart.lowerBound
        ]
        let settle = try #require(primaryBody.range(
            of: "Self.primaryCurrentInputSettleNanoseconds"
        ))
        let queuePolicy = try #require(primaryBody.range(
            of: "let queuedAutoSend = resolveQueuedAutoSend(autoSendKey)",
            range: settle.upperBound..<primaryBody.endIndex
        ))
        let returnPost = try #require(primaryBody.range(
            of: "CursorPaster.performAutoSend(",
            range: queuePolicy.upperBound..<primaryBody.endIndex
        ))
        #expect(settle.lowerBound < queuePolicy.lowerBound)
        #expect(queuePolicy.lowerBound < returnPost.lowerBound)
        #expect(primaryBody.contains(
            "auto-send deferred because a newer recording exists"
        ))
        #expect(primaryBody.contains(
            "auto-send skipped because this session was canceled"
        ))
        let issuedCallback = try #require(primaryBody.range(
            of: "onQueuedAutoSendIssued()",
            range: returnPost.upperBound..<primaryBody.endIndex
        ))
        #expect(returnPost.lowerBound < issuedCallback.lowerBound)

        let exactBody = deliverySource[
            exactStart.lowerBound..<deliverySource.endIndex
        ]
        #expect(!exactBody.contains("resolveQueuedAutoSend"))
        #expect(!exactBody.contains("queued Primary tail"))
        #expect(engineSource.contains(
            "session.pasteTarget.destination == .primaryCurrentInput"
        ))
        #expect(engineSource.contains(
            "session.completionDisposition == .normalDelivery"
        ))
        #expect(engineSource.contains("!session.skipPostProcessing"))
        #expect(engineSource.contains("!session.useCase.isAssistantFollowUp"))
        #expect(engineSource.contains(
            ").outputMode == .paste"
        ))
        #expect(engineSource.contains(
            "return .canceledCurrent(originalKey)"
        ))
        #expect(engineSource.contains(
            "newerRecordingStartPending: activeRecordingDeliveryBarrier"
        ))
        #expect(engineSource.contains(
            ".isDeliveryBlocked"
        ))

        let warningStart = try #require(engineSource.range(
            of: "    private func reportUnresolvedPrimaryAutoSendIfQueueDrained()"
        ))
        let dispatchStart = try #require(engineSource.range(
            of: "    // MARK: - Pipeline Dispatch",
            range: warningStart.upperBound..<engineSource.endIndex
        ))
        let warningBody = engineSource[
            warningStart.lowerBound..<dispatchStart.lowerBound
        ]
        #expect(warningBody.contains("compensatingReturn=false"))
        #expect(warningBody.contains("type: .warning"))
        #expect(warningBody.contains(
            "activeRecordingDeliveryBarrier.isDeliveryBlocked"
        ))
        #expect(!warningBody.contains("performAutoSend"))
        #expect(!warningBody.contains("CGEvent"))

        let queueRemoval = try #require(engineSource.range(
            of: "self.transcriptionJobRegistry.remove(identity)"
        ))
        let drainReport = try #require(engineSource.range(
            of: "self.reportUnresolvedPrimaryAutoSendIfQueueDrained()",
            range: queueRemoval.upperBound..<engineSource.endIndex
        ))
        #expect(queueRemoval.lowerBound < drainReport.lowerBound)
    }

    @MainActor
    @Test func serialQueueKeepsInjectedResultsBoundToFIFOJobIdentity() async throws {
        var registry = TranscriptionJobRegistry()
        let registeredA = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/session-a.wav")
        )
        let identityA = try #require(registeredA)
        let registeredB = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/session-b.wav")
        )
        let identityB = try #require(registeredB)
        let injectedResults = [
            identityA.transcriptionID: "result-a",
            identityB.transcriptionID: "result-b",
        ]
        let state = TranscriptionQueueTestState()
        state.currentIdentities = [identityA, identityB]
        let queue = SerialTranscriptionJobQueue()

        for identity in [identityA, identityB] {
            queue.enqueue(
                identity,
                isCurrent: { state.currentIdentities.contains($0) },
                onDiscard: { discarded in
                    state.events.append("discard:\(discarded.audioURL.lastPathComponent)")
                },
                operation: { running in
                    let result = injectedResults[running.transcriptionID] ?? "missing"
                    state.events.append("\(running.audioURL.lastPathComponent):\(result)")
                }
            )
        }

        await queue.waitUntilIdle()
        #expect(state.events == [
            "session-a.wav:result-a",
            "session-b.wav:result-b",
        ])
    }

    @MainActor
    @Test func eagerStreamingFinalsMayFinishInReverseButDeliverInRecordingOrder() async throws {
        var registry = TranscriptionJobRegistry()
        let registeredA = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/rapid-a.wav")
        )
        let identityA = try #require(registeredA)
        let registeredB = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/rapid-b.wav")
        )
        let identityB = try #require(registeredB)
        let finalizerA = TranscriptionFinalizationTask()
        let finalizerB = TranscriptionFinalizationTask()
        let gateA = TranscriptionQueueTestGate()
        let gateB = TranscriptionQueueTestGate()
        let state = TranscriptionQueueTestState()
        state.currentIdentities = [identityA, identityB]

        #expect(finalizerA.begin(audioURL: identityA.audioURL) { _ in
            state.events.append("provider-start:a")
            await gateA.wait()
            state.events.append("provider-finish:a")
            return "result-a"
        })
        #expect(finalizerB.begin(audioURL: identityB.audioURL) { _ in
            state.events.append("provider-start:b")
            await gateB.wait()
            state.events.append("provider-finish:b")
            return "result-b"
        })

        while state.events.filter({ $0.hasPrefix("provider-start:") }).count < 2 {
            await Task.yield()
        }

        let queue = SerialTranscriptionJobQueue()
        queue.enqueue(
            identityA,
            isCurrent: { state.currentIdentities.contains($0) },
            onDiscard: { _ in Issue.record("A must remain current") },
            operation: { running in
                let result = try? await finalizerA.value(
                    audioURL: running.audioURL,
                    operation: { _ in
                        Issue.record("A finalization must not run twice")
                        return "duplicate-a"
                    }
                )
                state.events.append("deliver:a:\(result ?? "error")")
            }
        )
        queue.enqueue(
            identityB,
            isCurrent: { state.currentIdentities.contains($0) },
            onDiscard: { _ in Issue.record("B must remain current") },
            operation: { running in
                let result = try? await finalizerB.value(
                    audioURL: running.audioURL,
                    operation: { _ in
                        Issue.record("B finalization must not run twice")
                        return "duplicate-b"
                    }
                )
                state.events.append("deliver:b:\(result ?? "error")")
            }
        )

        // B can finish its provider work while A is still finalizing, but FIFO
        // delivery must not paste B first or bind B's text to A's identity.
        await gateB.open()
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(state.events.contains("provider-finish:b"))
        #expect(!state.events.contains(where: { $0.hasPrefix("deliver:") }))

        await gateA.open()
        await queue.waitUntilIdle()
        #expect(state.events.filter({ $0.hasPrefix("deliver:") }) == [
            "deliver:a:result-a",
            "deliver:b:result-b",
        ])
    }

    @MainActor
    @Test func streamingFinalizationIsOneShotAndRejectsAnotherAudioFile() async throws {
        let finalizer = TranscriptionFinalizationTask()
        let audioA = URL(fileURLWithPath: "/tmp/one-shot-a.wav")
        let audioB = URL(fileURLWithPath: "/tmp/one-shot-b.wav")
        var operationCount = 0

        #expect(finalizer.begin(audioURL: audioA) { _ in
            operationCount += 1
            return "result-a"
        })
        #expect(!finalizer.begin(audioURL: audioA) { _ in
            operationCount += 1
            return "duplicate"
        })
        #expect(try await finalizer.value(
            audioURL: audioA,
            operation: { _ in "duplicate" }
        ) == "result-a")
        #expect(operationCount == 1)

        do {
            _ = try await finalizer.value(
                audioURL: audioB,
                operation: { _ in "wrong-audio" }
            )
            Issue.record("A finalizer must never accept B's audio URL")
        } catch let error as TranscriptionFinalizationTask.FinalizationError {
            #expect(error == .audioIdentityMismatch(
                expected: audioA.lastPathComponent,
                received: audioB.lastPathComponent
            ))
        } catch {
            Issue.record("Unexpected finalization error: \(error)")
        }
    }

    @MainActor
    @Test func cancelingOneEagerFinalizationCannotProduceItsResult() async throws {
        let finalizer = TranscriptionFinalizationTask()
        let audioURL = URL(fileURLWithPath: "/tmp/canceled-final.wav")
        let gate = TranscriptionQueueTestGate()
        let state = TranscriptionQueueTestState()

        #expect(finalizer.begin(audioURL: audioURL) { _ in
            state.events.append("started")
            await gate.wait()
            try Task.checkCancellation()
            return "must-not-deliver"
        })
        while state.events.isEmpty {
            await Task.yield()
        }

        finalizer.cancel()
        await gate.open()
        do {
            _ = try await finalizer.value(
                audioURL: audioURL,
                operation: { _ in "duplicate" }
            )
            Issue.record("Canceled finalization unexpectedly returned text")
        } catch is CancellationError {
            // Expected: cancellation of this session must stay local to its task.
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
    }

    @Test func assemblyAIStopFinalizationStartsBeforeItsSerialDeliveryTurn() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let engineSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/VoiceInkEngine.swift"
            ),
            encoding: .utf8
        )
        let sessionSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/TranscriptionSession.swift"
            ),
            encoding: .utf8
        )

        let eagerStart = try #require(engineSource.range(
            of: "job.transcriptionSession?.beginFinalization(audioURL: audioURL)"
        ))
        let serialEnqueue = try #require(engineSource.range(
            of: "transcriptionJobQueue.enqueue(",
            range: eagerStart.upperBound..<engineSource.endIndex
        ))
        #expect(eagerStart.lowerBound < serialEnqueue.lowerBound)
        #expect(sessionSource.contains(
            "eagerlyFinalizesAfterStop = model.provider == .assemblyAI || model.provider == .openAI"
        ))

        let startupWait = try #require(sessionSource.range(
            of: "await startupTask.value"
        ))
        let providerCommit = try #require(sessionSource.range(
            of: "streamingService.stopAndGetFinalText()",
            range: startupWait.upperBound..<sessionSource.endIndex
        ))
        #expect(startupWait.lowerBound < providerCommit.lowerBound)
    }

    @MainActor
    @Test func resetCannotResumeAWaitingJobOrAuthorizeRunningJobDelivery() async throws {
        var registry = TranscriptionJobRegistry()
        let registeredA = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/session-a.wav")
        )
        let identityA = try #require(registeredA)
        let registeredB = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/session-b.wav")
        )
        let identityB = try #require(registeredB)
        let state = TranscriptionQueueTestState()
        state.currentIdentities = [identityA, identityB]
        let gate = TranscriptionQueueTestGate()
        let queue = SerialTranscriptionJobQueue()

        queue.enqueue(
            identityA,
            isCurrent: { state.currentIdentities.contains($0) },
            onDiscard: { discarded in
                state.events.append("discard:\(discarded.audioURL.lastPathComponent)")
            },
            operation: { running in
                state.events.append("start:\(running.audioURL.lastPathComponent)")
                await gate.wait()
                if !Task.isCancelled, state.currentIdentities.contains(running) {
                    state.events.append("deliver:\(running.audioURL.lastPathComponent)")
                }
            }
        )
        queue.enqueue(
            identityB,
            isCurrent: { state.currentIdentities.contains($0) },
            onDiscard: { discarded in
                state.events.append("discard:\(discarded.audioURL.lastPathComponent)")
            },
            operation: { running in
                state.events.append("deliver:\(running.audioURL.lastPathComponent)")
            }
        )

        while state.events.isEmpty {
            await Task.yield()
        }
        state.currentIdentities.removeAll()
        let canceledTasks = queue.cancelAll()
        await gate.open()
        for task in canceledTasks {
            await task.value
        }

        #expect(state.events.contains("start:session-a.wav"))
        #expect(!state.events.contains("deliver:session-a.wav"))
        #expect(!state.events.contains("deliver:session-b.wav"))
    }

    @MainActor
    @Test func newGenerationWaitsForCanceledRunningJobToUnwind() async throws {
        var registry = TranscriptionJobRegistry()
        let registeredA = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/session-a.wav")
        )
        let identityA = try #require(registeredA)
        let state = TranscriptionQueueTestState()
        state.currentIdentities = [identityA]
        let gate = TranscriptionQueueTestGate()
        let queue = SerialTranscriptionJobQueue()

        queue.enqueue(
            identityA,
            isCurrent: { state.currentIdentities.contains($0) },
            onDiscard: { discarded in
                state.events.append("discard:\(discarded.audioURL.lastPathComponent)")
            },
            operation: { running in
                state.events.append("start:\(running.audioURL.lastPathComponent)")
                await gate.wait()
                state.events.append("unwind:\(running.audioURL.lastPathComponent)")
            }
        )

        while state.events.isEmpty {
            await Task.yield()
        }

        registry.invalidateAll()
        state.currentIdentities.removeAll()
        _ = queue.cancelAll()

        let registeredB = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/session-b.wav")
        )
        let identityB = try #require(registeredB)
        state.currentIdentities.insert(identityB)
        queue.enqueue(
            identityB,
            isCurrent: { state.currentIdentities.contains($0) },
            onDiscard: { discarded in
                state.events.append("discard:\(discarded.audioURL.lastPathComponent)")
            },
            operation: { running in
                state.events.append("start:\(running.audioURL.lastPathComponent)")
            }
        )

        // B must remain behind the reset barrier while canceled A is still unwinding.
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(state.events == ["start:session-a.wav"])

        await gate.open()
        await queue.waitUntilIdle()
        #expect(state.events == [
            "start:session-a.wav",
            "unwind:session-a.wav",
            "start:session-b.wav",
        ])
    }

    @Test func transcriptionLineageDigestDistinguishesResultsWithoutContainingText() {
        let first = TranscriptionLineageDigest.make("first private transcript")
        let second = TranscriptionLineageDigest.make("second private transcript")

        #expect(first.count == 16)
        #expect(second.count == 16)
        #expect(first != second)
        #expect(!first.contains("first"))
        #expect(!second.contains("second"))
    }

    @Test func sharedTranscriptionResourcesCannotCrossLiveSessionBoundaries() {
        #expect(SharedTranscriptionResourcePolicy.allowsSpeculativePreload(liveSessionCount: 1))
        #expect(!SharedTranscriptionResourcePolicy.allowsSpeculativePreload(liveSessionCount: 2))

        #expect(SharedTranscriptionResourcePolicy.allowsCleanup(
            liveSessionCount: 0,
            retiringOwnerIsCurrent: true
        ))
        #expect(!SharedTranscriptionResourcePolicy.allowsCleanup(
            liveSessionCount: 1,
            retiringOwnerIsCurrent: true
        ))
        #expect(!SharedTranscriptionResourcePolicy.allowsCleanup(
            liveSessionCount: 0,
            retiringOwnerIsCurrent: false
        ))
    }

    @Test func recorderVersionSplitsMarketingAndBuildAcrossTwoRows() {
        let presentation = RecorderVersionPresentation(
            marketingVersion: "2.0",
            buildNumber: "236"
        )

        #expect(presentation.topLine == "v2.0")
        #expect(presentation.bottomLine == ".236")
        #expect(presentation.accessibilityLabel == "VoiceInk++ version 2.0, build 236")
    }

    @MainActor
    @Test func primaryCurrentInputStructurallyRejectsExactDeliveryState() {
        let accidentalDestinationMode = ModeConfig(
            name: "Must be discarded",
            isAIEnhancementEnabled: false,
            outputMode: .paste,
            autoSendKey: .enter
        )
        let primary = RecordingPasteTarget(
            destination: .primaryCurrentInput,
            focusedInput: nil,
            mode: accidentalDestinationMode
        )

        #expect(RecordingPasteDestination.primaryCurrentInput.usesBaseCurrentInputDelivery)
        #expect(!RecordingPasteDestination.primaryCurrentInput.usesAppSpecificExactDelivery)
        #expect(RecordingPasteDestination.recordingStart.usesAppSpecificExactDelivery)
        #expect(RecordingPasteDestination.focusedDuringTranscription.usesAppSpecificExactDelivery)
        #expect(primary.focusedInput == nil)
        #expect(primary.mode == nil)
        #expect(primary.resolvedAutoSendKey(currentInputKey: .commandEnter) == AutoSendKey.commandEnter)

        let latched = RecordingPasteTarget(
            destination: .focusedDuringTranscription,
            focusedInput: nil,
            mode: accidentalDestinationMode
        )
        #expect(latched.mode == accidentalDestinationMode)
        #expect(latched.resolvedAutoSendKey(currentInputKey: .shiftEnter) == AutoSendKey.enter)
    }

    @MainActor
    @Test func backgroundAutoSendSeparatesUnreadableFromReadableNoOp() {
        #expect(TranscriptionDelivery.classifyBackgroundAutoSendVerification(
            previousText: "latched transcript",
            currentText: nil
        ) == .unreadable)
        #expect(TranscriptionDelivery.classifyBackgroundAutoSendVerification(
            previousText: "latched transcript",
            currentText: "latched transcript"
        ) == .unchanged)
        #expect(TranscriptionDelivery.classifyBackgroundAutoSendVerification(
            previousText: "latched transcript",
            currentText: ""
        ) == .verifiedCleared)
        #expect(TranscriptionDelivery.classifyBackgroundAutoSendVerification(
            previousText: "latched transcript",
            currentText: "latched transcript\n"
        ) == .modifiedWithoutSubmit)
        #expect(TranscriptionDelivery.classifyBackgroundAutoSendVerification(
            previousText: "latched transcript",
            currentText: "Ask for follow-up changes",
            currentPlaceholder: "Ask for follow-up changes"
        ) == .verifiedCleared)
        #expect(TranscriptionDelivery.classifyBackgroundAutoSendVerification(
            previousText: "latched transcript",
            currentText: "unrelated reset status",
            currentPlaceholder: nil
        ) == .unreadable)

        #expect(TranscriptionDelivery.classifyForegroundOpenAIAutoSendVerification(
            previousText: "latched transcript",
            currentText: nil,
            currentPlaceholder: "Ask for follow-up changes"
        ) == .unreadable)
        #expect(TranscriptionDelivery.classifyForegroundOpenAIAutoSendVerification(
            previousText: "latched transcript",
            currentText: "latched transcript\n",
            currentPlaceholder: "Ask for follow-up changes"
        ) == .modifiedWithoutSubmit)
        #expect(TranscriptionDelivery.classifyForegroundOpenAIAutoSendVerification(
            previousText: "latched transcript",
            currentText: "Ask for follow-up changes",
            currentPlaceholder: "Ask for follow-up changes"
        ) == .verifiedCleared)
        #expect(TranscriptionDelivery.classifyForegroundOpenAIAutoSendVerification(
            previousText: "Ask for follow-up changes",
            currentText: "Ask for follow-up changes",
            currentPlaceholder: "Ask for follow-up changes"
        ) == .unchanged)
        #expect(TranscriptionDelivery.classifyForegroundOpenAIAutoSendVerification(
            previousText: "latched transcript",
            currentText: "latched transcript\nnew draft",
            currentPlaceholder: "Ask for follow-up changes"
        ) == .modifiedWithoutSubmit)
        #expect(TranscriptionDelivery.classifyForegroundOpenAIAutoSendVerification(
            previousText: "latched transcript",
            currentText: "unrelated reset status",
            currentPlaceholder: nil
        ) == .unreadable)

        #expect(TranscriptionDelivery.backgroundAutoSendUserFeedback(
            verification: .unreadable
        ) == .none)
        #expect(TranscriptionDelivery.backgroundAutoSendUserFeedback(
            verification: .verifiedCleared
        ) == .none)
        #expect(TranscriptionDelivery.backgroundAutoSendUserFeedback(
            verification: .unchanged
        ) == .unchangedComposerError)
        #expect(TranscriptionDelivery.backgroundAutoSendUserFeedback(
            verification: .modifiedWithoutSubmit
        ) == .modifiedWithoutSubmitError)

        #expect(TranscriptionDelivery.autoSendOutcome(
            verification: .verifiedCleared
        ) == .verified)
        #expect(TranscriptionDelivery.autoSendOutcome(
            verification: .unreadable
        ) == .indeterminate)
        #expect(TranscriptionDelivery.autoSendOutcome(
            verification: .unchanged
        ) == .failed)
        #expect(TranscriptionDelivery.autoSendOutcome(
            verification: .modifiedWithoutSubmit
        ) == .failed)

        #expect(TranscriptionDelivery.foregroundOpenAIAutoSendOutcome(
            verification: .verifiedCleared,
            exactTargetStillOwnsKeyboardFocus: false
        ) == .verified)
        #expect(TranscriptionDelivery.foregroundOpenAIAutoSendOutcome(
            verification: .unchanged,
            exactTargetStillOwnsKeyboardFocus: true
        ) == .failed)
        #expect(TranscriptionDelivery.foregroundOpenAIAutoSendOutcome(
            verification: .modifiedWithoutSubmit,
            exactTargetStillOwnsKeyboardFocus: true
        ) == .failed)
        #expect(TranscriptionDelivery.foregroundOpenAIAutoSendOutcome(
            verification: .unchanged,
            exactTargetStillOwnsKeyboardFocus: false
        ) == .indeterminate)
        #expect(TranscriptionDelivery.foregroundOpenAIAutoSendOutcome(
            verification: .modifiedWithoutSubmit,
            exactTargetStillOwnsKeyboardFocus: false
        ) == .indeterminate)

        #expect(TranscriptionDelivery.shouldRetryForegroundOpenAIReturn(
            bundleIdentifier: "com.openai.codex",
            autoSendKey: .enter,
            verification: .unchanged,
            exactTargetStillOwnsKeyboardFocus: true
        ))
        #expect(!TranscriptionDelivery.shouldRetryForegroundOpenAIReturn(
            bundleIdentifier: "com.openai.codex",
            autoSendKey: .enter,
            verification: .modifiedWithoutSubmit,
            exactTargetStillOwnsKeyboardFocus: true
        ))
        #expect(!TranscriptionDelivery.shouldRetryForegroundOpenAIReturn(
            bundleIdentifier: "com.openai.codex",
            autoSendKey: .enter,
            verification: .unchanged,
            exactTargetStillOwnsKeyboardFocus: false
        ))
        #expect(!TranscriptionDelivery.shouldRetryForegroundOpenAIReturn(
            bundleIdentifier: "ru.keepcoder.Telegram",
            autoSendKey: .enter,
            verification: .unchanged,
            exactTargetStillOwnsKeyboardFocus: true
        ))
        #expect(!TranscriptionDelivery.shouldRetryForegroundOpenAIReturn(
            bundleIdentifier: "com.openai.codex",
            autoSendKey: .shiftEnter,
            verification: .unchanged,
            exactTargetStillOwnsKeyboardFocus: true
        ))
    }

    @MainActor
    @Test func backgroundFocusSnapshotRestoresFalseAndOmitsUnreadableValues() {
        typealias Slot = FocusLockService.BackgroundFocusBooleanSlot
        let snapshot = FocusLockService.BackgroundFocusBooleanSnapshot { slot in
            switch slot {
            case .targetWindowMain: false
            case .targetWindowFocused: false
            case .targetElementFocused: true
            case .previousWindowMain: true
            case .previousWindowFocused: true
            case .previousElementFocused: nil
            }
        }
        var restored: [Slot: Bool] = [:]

        #expect(snapshot.restore { slot, value in
            restored[slot] = value
            return true
        })
        #expect(restored[.targetWindowMain] == false)
        #expect(restored[.targetWindowFocused] == false)
        #expect(restored[.targetElementFocused] == true)
        #expect(restored[.previousWindowMain] == true)
        #expect(restored[.previousWindowFocused] == true)
        #expect(restored[.previousElementFocused] == nil)
        #expect(snapshot.matches { restored[$0] })
        #expect(!snapshot.containsAll([.previousElementFocused]))
        #expect(snapshot.missing(from: [.targetWindowMain, .previousElementFocused]) == [
            .previousElementFocused
        ])

        var restorationOrder: [Slot] = []
        #expect(snapshot.restore { slot, _ in
            restorationOrder.append(slot)
            return true
        })
        #expect(restorationOrder == [
            .targetWindowMain,
            .targetWindowFocused,
            .targetElementFocused,
            .previousWindowMain,
            .previousWindowFocused
        ])

        var attempted: [Slot] = []
        #expect(!snapshot.restore { slot, _ in
            attempted.append(slot)
            return slot != .targetWindowFocused
        })
        #expect(attempted.contains(.previousWindowFocused))
    }

    @MainActor
    @Test func telegramRetainedInputRequiresReadableMatchingChatAndInternalFocus() {
        let captured = [
            "VoiceInk Telegram disposable context anchor",
            "Saved Messages stable disposable context"
        ]
        #expect(FocusLockService.isTelegram(
            bundleIdentifier: "ru.keepcoder.Telegram"
        ))
        #expect(!FocusLockService.isTelegram(
            bundleIdentifier: "com.openai.codex"
        ))
        #expect(FocusLockService.telegramRetainedInputAllowed(
            capturedContextAnchors: captured,
            currentContextAnchors: captured,
            internalFocusMatches: true,
            structureMatches: true
        ))
        #expect(!FocusLockService.telegramRetainedInputAllowed(
            capturedContextAnchors: captured,
            currentContextAnchors: [],
            internalFocusMatches: true,
            structureMatches: true
        ))
        #expect(!FocusLockService.telegramRetainedInputAllowed(
            capturedContextAnchors: captured,
            currentContextAnchors: ["Different disposable chat"],
            internalFocusMatches: true,
            structureMatches: true
        ))
        #expect(!FocusLockService.telegramRetainedInputAllowed(
            capturedContextAnchors: captured,
            currentContextAnchors: captured,
            internalFocusMatches: false,
            structureMatches: true
        ))
        #expect(!FocusLockService.telegramRetainedInputAllowed(
            capturedContextAnchors: captured,
            currentContextAnchors: captured,
            internalFocusMatches: true,
            structureMatches: false
        ))
    }

    @MainActor
    @Test func telegramParentlessComposerRequiresOneEnclosingWindow() {
        let composer = CGRect(x: 120, y: 740, width: 540, height: 52)
        #expect(FocusLockService.uniqueContainingWindowIndex(
            elementFrame: composer,
            windowFrames: [
                CGRect(x: 900, y: 50, width: 60, height: 20),
                CGRect(x: 80, y: 100, width: 650, height: 760)
            ]
        ) == 1)
        #expect(FocusLockService.uniqueContainingWindowIndex(
            elementFrame: composer,
            windowFrames: [
                CGRect(x: 80, y: 100, width: 650, height: 760),
                CGRect(x: 100, y: 700, width: 600, height: 100)
            ]
        ) == nil)
        #expect(FocusLockService.uniqueContainingWindowIndex(
            elementFrame: composer,
            windowFrames: [nil, CGRect(x: 0, y: 0, width: 40, height: 40)]
        ) == nil)
    }

    @MainActor
    @Test func nextTrackNeverPassesThroughWhileRecorderPanelIsVisible() {
        #expect(RecordingShortcutManager
            .shouldConsumeNextTrackWithoutEligibleRoute(
                isRecorderPanelVisible: true
            ))
        #expect(!RecordingShortcutManager
            .shouldConsumeNextTrackWithoutEligibleRoute(
                isRecorderPanelVisible: false
            ))
    }

    @Test func telegramVisualIdentityPinsTupleCropAndStableDigest() {
        let tuple = TelegramWindowVisualIdentity.ApplicationTuple(
            applicationBundleName: "Telegram.app",
            bundleIdentifier: "ru.keepcoder.Telegram",
            shortVersion: "12.9",
            build: "282526"
        )
        #expect(TelegramWindowVisualIdentityService.isAudited(tuple))
        #expect(TelegramWindowVisualIdentityService.pixelCropRect(
            imageWidth: 407,
            imageHeight: 997
        ) == CGRect(x: 48, y: 34, width: 262, height: 66))
        #expect(TelegramWindowVisualIdentityService.pixelStableChatIdentityRect(
            imageWidth: 262,
            imageHeight: 66
        ) == CGRect(x: 141, y: 22, width: 116, height: 35))

        let stable = TelegramWindowVisualIdentityService.HeaderDigestSample(
            width: 407,
            height: 997,
            digest: Data([1, 2, 3, 4]),
            stableChatIdentityDigest: Data([5, 6, 7, 8])
        )
        let identity = TelegramWindowVisualIdentityService.stableIdentity(
            applicationTuple: tuple,
            processIdentifier: 737,
            windowID: 244,
            first: stable,
            second: stable
        )
        #expect(identity?.windowID == 244)
        #expect(identity?.headerDigest == stable.digest)
        #expect(identity?.stableChatIdentityDigest == stable.stableChatIdentityDigest)

        // Dynamic status pixels may change while the exact avatar/title row remains
        // identical. This is the Telegram v2.0.245 false-rejection regression.
        #expect(TelegramWindowVisualIdentityService.stableIdentity(
            applicationTuple: tuple,
            processIdentifier: 737,
            windowID: 244,
            first: stable,
            second: .init(
                width: 407,
                height: 997,
                digest: Data([9, 9, 9, 9]),
                stableChatIdentityDigest: stable.stableChatIdentityDigest
            )
        ) != nil)

        #expect(TelegramWindowVisualIdentityService.stableIdentity(
            applicationTuple: tuple,
            processIdentifier: 737,
            windowID: 244,
            first: stable,
            second: .init(
                width: 407,
                height: 997,
                digest: Data([9, 9, 9, 9]),
                stableChatIdentityDigest: Data([8, 7, 6, 5])
            )
        ) == nil)
        #expect(!TelegramWindowVisualIdentityService.isAudited(.init(
            applicationBundleName: "Telegram.app",
            bundleIdentifier: "ru.keepcoder.Telegram",
            shortVersion: "12.10",
            build: "282527"
        )))
    }

    @MainActor
    @Test func telegramAccessibilityInsertionFallbackIsOneShot() async {
        var accessibilityAttempts = 0
        var unicodeAttempts = 0
        var accessibilityErrors: [Int32] = []

        let fallbackSucceeded = await TranscriptionDelivery
            .executeAccessibilityFirstBackgroundInsertion(
                allowsTargetedUnicodeFallback: true,
                attemptAccessibility: {
                    accessibilityAttempts += 1
                    return .unavailable
                },
                fullBoundaryMatches: { true },
                targetedUnicode: { boundary in
                    unicodeAttempts += 1
                    return boundary()
                }
            )
        #expect(fallbackSucceeded)
        #expect(accessibilityAttempts == 1)
        #expect(unicodeAttempts == 1)

        let setterErrorWasNotRetried = await TranscriptionDelivery
            .executeAccessibilityFirstBackgroundInsertion(
                allowsTargetedUnicodeFallback: true,
                attemptAccessibility: {
                    accessibilityAttempts += 1
                    return .failed(AXError.cannotComplete.rawValue)
                },
                fullBoundaryMatches: { true },
                onAccessibilityError: { accessibilityErrors.append($0) },
                targetedUnicode: { _ in
                    unicodeAttempts += 1
                    return true
                }
            )
        #expect(setterErrorWasNotRetried)
        #expect(accessibilityAttempts == 2)
        #expect(unicodeAttempts == 1)
        #expect(accessibilityErrors == [AXError.cannotComplete.rawValue])

        let directExactInputFailedClosed = await TranscriptionDelivery
            .executeAccessibilityFirstBackgroundInsertion(
                allowsTargetedUnicodeFallback: false,
                attemptAccessibility: { .unavailable },
                fullBoundaryMatches: { true },
                targetedUnicode: { _ in
                    unicodeAttempts += 1
                    return true
                }
            )
        #expect(!directExactInputFailedClosed)
        #expect(unicodeAttempts == 1)
    }

    @MainActor
    @Test func telegramIsAChatComposerButNeverAnOpenAIReturnRetry() {
        #expect(TranscriptionDelivery.isChatComposer(
            bundleIdentifier: "ru.keepcoder.Telegram"
        ))
        #expect(TranscriptionDelivery.isChatComposer(
            bundleIdentifier: "com.openai.codex"
        ))
        #expect(!TranscriptionDelivery.isChatComposer(
            bundleIdentifier: "com.apple.Terminal"
        ))
        #expect(!TranscriptionDelivery.shouldRetryForegroundOpenAIReturn(
            bundleIdentifier: "ru.keepcoder.Telegram",
            autoSendKey: .enter,
            verification: .unchanged,
            exactTargetStillOwnsKeyboardFocus: true
        ))
    }

    @Test func telegramRetainedSessionNeverWritesAXFocusPointers() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Modes/FocusLockService.swift"
            ),
            encoding: .utf8
        )
        let prepareStart = try #require(source.range(
            of: "    private func prepareRetainedTelegramBackgroundDelivery("
        ))
        let prepareEnd = try #require(source.range(
            of: "    static func runBackgroundPreparationWithOwnedFailureCleanup(",
            range: prepareStart.upperBound..<source.endIndex
        ))
        let prepareBody = source[
            prepareStart.lowerBound..<prepareEnd.lowerBound
        ]
        #expect(prepareBody.contains("CursorPaster.beginTargetedInputSession"))
        #expect(prepareBody.contains("telegramDeliveryBoundaryMatches"))
        #expect(!prepareBody.contains("AXUIElementSetAttributeValue"))

        let finishStart = try #require(source.range(
            of: "    private func finishRetainedTelegramBackgroundDelivery("
        ))
        let finishEnd = try #require(source.range(
            of: "    func finishBackgroundDelivery(",
            range: finishStart.upperBound..<source.endIndex
        ))
        let finishBody = source[
            finishStart.lowerBound..<finishEnd.lowerBound
        ]
        #expect(finishBody.contains("CursorPaster.endTargetedInputSession"))
        #expect(!finishBody.contains("AXUIElementSetAttributeValue"))
    }

    @MainActor
    @Test func backgroundFocusPreservesExplicitlyAbsentPriorEditor() {
        #expect(FocusLockService.priorFocusedElementReadIsRestorable(.value))
        #expect(FocusLockService.priorFocusedElementReadIsRestorable(.absent))
        #expect(!FocusLockService.priorFocusedElementReadIsRestorable(.failed))

        #expect(FocusLockService.absentPriorFocusedElementRestorationMatches(
            restoredAvailability: .absent,
            restoredElementMatchesTarget: false,
            restoredTargetFocused: nil,
            expectedTargetFocused: false
        ))
        #expect(FocusLockService.absentPriorFocusedElementRestorationMatches(
            restoredAvailability: .value,
            restoredElementMatchesTarget: true,
            restoredTargetFocused: false,
            expectedTargetFocused: false
        ))
        #expect(!FocusLockService.absentPriorFocusedElementRestorationMatches(
            restoredAvailability: .value,
            restoredElementMatchesTarget: false,
            restoredTargetFocused: false,
            expectedTargetFocused: false
        ))
        #expect(!FocusLockService.absentPriorFocusedElementRestorationMatches(
            restoredAvailability: .value,
            restoredElementMatchesTarget: true,
            restoredTargetFocused: true,
            expectedTargetFocused: false
        ))
        #expect(!FocusLockService.absentPriorFocusedElementRestorationMatches(
            restoredAvailability: .failed,
            restoredElementMatchesTarget: false,
            restoredTargetFocused: nil,
            expectedTargetFocused: false
        ))
    }

    @Test func exactNextDeliveryToleratesTransientSystemFocusReadUnavailability() {
        #expect(FocusLockService.systemFocusReadRetryAttempts == 9)
        #expect(
            FocusLockService.systemFocusReadRetryIntervalNanoseconds
                * UInt64(FocusLockService.systemFocusReadRetryAttempts - 1)
                == 200_000_000
        )
    }

    @Test func cooperativeQuitIsBlockedWhileAnySessionIsInFlight() {
        #expect(AppDelegate.shouldBlockTermination(hasInFlightSessions: true))
        #expect(!AppDelegate.shouldBlockTermination(hasInFlightSessions: false))
    }

    @MainActor
    @Test func backgroundFocusSessionLifecycleIsOneShotAndOwnsPartialCleanup() {
        var lifecycle = FocusLockService.BackgroundFocusSessionLifecycle()
        var beginCount = 0
        var endCount = 0

        #expect(lifecycle.canBegin)
        let began = lifecycle.begin {
            beginCount += 1
            return true
        }
        #expect(began)
        #expect(beginCount == 1)
        #expect(!lifecycle.canBegin)
        let beganAgain = lifecycle.begin {
            beginCount += 1
            return true
        }
        #expect(!beganAgain)
        #expect(beginCount == 1)
        #expect(lifecycle.requiresTeardown)
        let scheduledRetry = lifecycle.markTeardownRetryScheduled()
        #expect(scheduledRetry)
        #expect(lifecycle.state == .teardownRetryScheduled)
        let scheduledRetryAgain = lifecycle.markTeardownRetryScheduled()
        #expect(!scheduledRetryAgain)
        let finished = lifecycle.finish { endCount += 1 }
        #expect(finished)
        #expect(endCount == 1)
        #expect(lifecycle.state == .finished)
        let finishedAgain = lifecycle.finish { endCount += 1 }
        #expect(!finishedAgain)
        #expect(endCount == 1)

        var beginFailed = FocusLockService.BackgroundFocusSessionLifecycle()
        let failedToBegin = beginFailed.begin {
            beginCount += 1
            return false
        }
        #expect(!failedToBegin)
        #expect(beginFailed.state == .ready)
        let finishedWithoutBegin = beginFailed.finish { endCount += 1 }
        #expect(!finishedWithoutBegin)
        #expect(endCount == 1)

        var waived = FocusLockService.BackgroundFocusSessionLifecycle()
        let beganWaivedSession = waived.begin { true }
        #expect(beganWaivedSession)
        let waivedSession = waived.waiveTeardown()
        #expect(waivedSession)
        #expect(waived.state == .teardownWaived)
        let finishedWaivedSession = waived.finish { endCount += 1 }
        #expect(!finishedWaivedSession)
        #expect(endCount == 1)

        var waivedAfterRetry = FocusLockService.BackgroundFocusSessionLifecycle()
        let beganRetryWaiver = waivedAfterRetry.begin { true }
        #expect(beganRetryWaiver)
        let scheduledRetryBeforeWaiver = waivedAfterRetry.markTeardownRetryScheduled()
        #expect(scheduledRetryBeforeWaiver)
        let waivedRetry = waivedAfterRetry.waiveTeardown()
        #expect(waivedRetry)
        #expect(waivedAfterRetry.state == .teardownWaived)
        let finishedRetryWaiver = waivedAfterRetry.finish { endCount += 1 }
        #expect(!finishedRetryWaiver)
        #expect(endCount == 1)
    }

    @MainActor
    @Test func backgroundTeardownDecisionCoversEveryTerminalBoundary() {
        typealias Decision = FocusLockService.BackgroundTeardownDecision
        typealias Boundary = FocusLockService.BackgroundTeardownBoundaryStatus

        #expect(FocusLockService.backgroundTeardownDecision(
            boundary: .safe,
            restorationIncomplete: false,
            retryCount: 0
        ) == Decision.restoreNow)
        #expect(FocusLockService.backgroundTeardownDecision(
            boundary: .safe,
            restorationIncomplete: false,
            retryCount: 1
        ) == Decision.restoreNow)
        #expect(FocusLockService.backgroundTeardownDecision(
            boundary: .safe,
            restorationIncomplete: true,
            retryCount: 0
        ) == Decision.retryFullRestoration)
        #expect(FocusLockService.backgroundTeardownDecision(
            boundary: .safe,
            restorationIncomplete: true,
            retryCount: 1
        ) == Decision.finishPartialAndEnd)

        for unavailable in [Boundary.frontmostUnavailable, .systemFocusUnavailable] {
            #expect(FocusLockService.backgroundTeardownDecision(
                boundary: unavailable,
                restorationIncomplete: false,
                retryCount: 0
            ) == Decision.retryFullRestoration)
            #expect(FocusLockService.backgroundTeardownDecision(
                boundary: unavailable,
                restorationIncomplete: false,
                retryCount: 1
            ) == Decision.waiveWithoutMutation)
            #expect(FocusLockService.backgroundTeardownDecision(
                boundary: unavailable,
                restorationIncomplete: true,
                retryCount: 1
            ) == Decision.waiveWithoutMutation)
        }

        for terminal in [Boundary.targetOwnsSystemFocus, .targetTerminated] {
            #expect(FocusLockService.backgroundTeardownDecision(
                boundary: terminal,
                restorationIncomplete: true,
                retryCount: 0
            ) == Decision.waiveWithoutMutation)
        }

        let takeover = FocusLockService.preservedBackgroundTeardownBoundary(
            current: .safe,
            observed: .targetOwnsSystemFocus
        )
        #expect(takeover == .targetOwnsSystemFocus)
        #expect(FocusLockService.preservedBackgroundTeardownBoundary(
            current: takeover,
            observed: .frontmostUnavailable
        ) == .targetOwnsSystemFocus)
        #expect(FocusLockService.preservedBackgroundTeardownBoundary(
            current: takeover,
            observed: .safe
        ) == .targetOwnsSystemFocus)
    }

    @MainActor
    @Test func failedBackgroundFocusPreparationBehaviorallyInvokesOwnedCleanup() async {
        var cleanupCount = 0
        let failed = await FocusLockService.runBackgroundPreparationWithOwnedFailureCleanup(
            prepare: { false },
            cleanup: { cleanupCount += 1 }
        )
        #expect(!failed)
        #expect(cleanupCount == 1)

        let succeeded = await FocusLockService.runBackgroundPreparationWithOwnedFailureCleanup(
            prepare: { true },
            cleanup: { cleanupCount += 1 }
        )
        #expect(succeeded)
        #expect(cleanupCount == 1)

        var lifecycle = FocusLockService.BackgroundFocusSessionLifecycle()
        var beginCount = 0
        var endCount = 0
        let failedAfterBegin = await FocusLockService.runBackgroundPreparationWithOwnedFailureCleanup(
            prepare: {
                let began = lifecycle.begin {
                    beginCount += 1
                    return true
                }
                #expect(began)
                return false
            },
            cleanup: {
                let finished = lifecycle.finish { endCount += 1 }
                #expect(finished)
            }
        )
        #expect(!failedAfterBegin)
        #expect(beginCount == 1)
        #expect(endCount == 1)
        #expect(lifecycle.state == .finished)
        let finishedAgain = lifecycle.finish { endCount += 1 }
        #expect(!finishedAgain)
        #expect(endCount == 1)
    }

    @MainActor
    @Test func unlabelledOpenAISendExceptionIsPinnedToExactAppAndBuildTuples() {
        #expect(FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "Codex.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.707.72221",
            build: "5307",
            chromium: "150.0.7871.115"
        ))
        #expect(FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.715.31925",
            build: "5551",
            chromium: "150.0.7871.124"
        ))
        #expect(FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.715.52143",
            build: "5591",
            chromium: "150.0.7871.124"
        ))
        #expect(FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.715.70719",
            build: "5650",
            chromium: "150.0.7871.124"
        ))
        #expect(FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.721.30844",
            build: "5813",
            chromium: "150.0.7871.128"
        ))
        #expect(FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.721.31836",
            build: "5828",
            chromium: "150.0.7871.128"
        ))
        #expect(FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.727.51351",
            build: "6119",
            chromium: "150.0.7871.182"
        ))
        #expect(FocusLockService.isAuditedOpenAIRetainedPreparationBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.727.51351",
            build: "6119",
            chromium: "150.0.7871.182"
        ))
        #expect(!FocusLockService.isAuditedOpenAIRetainedPreparationBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.727.51351",
            build: "6120",
            chromium: "150.0.7871.182"
        ))
        #expect(!FocusLockService.isAuditedOpenAIRetainedPreparationBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.727.51351",
            build: "6119",
            chromium: "150.0.7871.183"
        ))
        #expect(!FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.707.72221",
            build: "5307",
            chromium: "150.0.7871.115"
        ))
        #expect(!FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "Codex.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.715.31925",
            build: "5551",
            chromium: "150.0.7871.124"
        ))
        #expect(!FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "Codex.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.707.72222",
            build: "5308",
            chromium: "150.0.7871.115"
        ))
        #expect(!FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.715.31925",
            build: "5551",
            chromium: nil
        ))
        #expect(!FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.715.52143",
            build: "5592",
            chromium: "150.0.7871.124"
        ))
        #expect(!FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.715.70719",
            build: "5651",
            chromium: "150.0.7871.124"
        ))
        #expect(!FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.721.30844",
            build: "5814",
            chromium: "150.0.7871.128"
        ))
        #expect(!FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.721.30844",
            build: "5813",
            chromium: "150.0.7871.129"
        ))
        #expect(!FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.721.31836",
            build: "5829",
            chromium: "150.0.7871.128"
        ))
        #expect(!FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.721.31836",
            build: "5828",
            chromium: "150.0.7871.129"
        ))
        #expect(!FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.727.51351",
            build: "6120",
            chromium: "150.0.7871.182"
        ))
        #expect(!FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.727.51351",
            build: "6119",
            chromium: "150.0.7871.183"
        ))
        #expect(!FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.chat",
            shortVersion: "26.715.31925",
            build: "5551",
            chromium: "150.0.7871.124"
        ))

    }

    @Test func chatGPTRetainedSessionNeverWritesAXFocusPointers() throws {
        let source = try repositorySource(
            "VoiceInk/Modes/FocusLockService.swift"
        )
        let prepareStart = try #require(source.range(
            of: "    private func prepareRetainedOpenAIBackgroundDelivery("
        ))
        let prepareEnd = try #require(source.range(
            of: "    /// Telegram retains a valid editor wrapper",
            range: prepareStart.upperBound..<source.endIndex
        ))
        let prepareBody = source[
            prepareStart.lowerBound..<prepareEnd.lowerBound
        ]

        #expect(prepareBody.contains(
            "matchesAuditedOpenAIRetainedPreparationBuild"
        ))
        #expect(prepareBody.contains("CursorPaster.beginTargetedInputSession"))
        #expect(prepareBody.contains("resolvedExactElement"))
        #expect(prepareBody.contains("internalWindow"))
        #expect(prepareBody.contains("internalElement"))
        #expect(!prepareBody.contains("AXUIElementSetAttributeValue"))

        let finishStart = try #require(source.range(
            of: "    private func finishRetainedNonMutatingBackgroundDelivery("
        ))
        let finishEnd = try #require(source.range(
            of: "    func finishBackgroundDelivery(",
            range: finishStart.upperBound..<source.endIndex
        ))
        let finishBody = source[
            finishStart.lowerBound..<finishEnd.lowerBound
        ]
        #expect(finishBody.contains("CursorPaster.endTargetedInputSession"))
        #expect(!finishBody.contains("AXUIElementSetAttributeValue"))
    }

    @Test func targetedOpenAISendClickIsFailClosedAndOneShot() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let delivery = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/TranscriptionDelivery.swift"
            ),
            encoding: .utf8
        )
        let backgroundStart = try #require(delivery.range(
            of: "    private func performBackgroundAutoSend("
        ))
        let backgroundEnd = try #require(delivery.range(
            of: "    private func waitForBackgroundInsertion(",
            range: backgroundStart.upperBound..<delivery.endIndex
        ))
        let backgroundRoute = delivery[
            backgroundStart.lowerBound..<backgroundEnd.lowerBound
        ]
        #expect(backgroundRoute.contains("case .targetedClick:"))
        #expect(backgroundRoute.contains("skyLightTargetedSendClick"))
        #expect(backgroundRoute.contains("semanticAXPress"))
        #expect(backgroundRoute.contains("telegramTargetedHIDReturn"))
        #expect(backgroundRoute.contains("performTargetedTelegramHIDReturn"))
        #expect(backgroundRoute.contains(
            "revalidateTelegramVisualIdentityIfRequired"
        ))
        #expect(!backgroundRoute.contains("authenticatedSkyLightReturn"))
        #expect(!backgroundRoute.contains("performAuthenticatedTargetedReturn"))
        #expect(!backgroundRoute.contains("CursorPaster.performAutoSend"))

        let bridge = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Paste/SkyLightTargetedMouseEventPost.swift"
            ),
            encoding: .utf8
        )
        #expect(bridge.contains("SLEventPostToPid"))
        #expect(bridge.contains("SLEventSetIntegerValueField"))
        #expect(bridge.contains("CGEventSetWindowLocation"))
        #expect(bridge.contains("_AXUIElementGetWindow"))
        #expect(bridge.contains("clock_gettime_nsec_np(CLOCK_UPTIME_RAW)"))
        #expect(!bridge.contains("SLEventSetAuthenticationMessage"))
        #expect(!bridge.contains("event.postToPid("))
        #expect(!bridge.contains("event.post(tap:"))

        let paster = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Paste/CursorPaster.swift"
            ),
            encoding: .utf8
        )
        let primitiveStart = try #require(paster.range(
            of: "    static func performTargetedOpenAISendClick("
        ))
        let primitiveEnd = try #require(paster.range(
            of: "    @MainActor\n    private static func makeOtherEvent(",
            range: primitiveStart.upperBound..<paster.endIndex
        ))
        let primitive = paster[
            primitiveStart.lowerBound..<primitiveEnd.lowerBound
        ]
        let lastPreparation = try #require(primitive.range(
            of: "targetUp,\n                targetPID: targetPID"
        ))
        let firstPost = try #require(primitive.range(
            of: "postPreparedEvent(\n            move"
        ))
        #expect(lastPreparation.lowerBound < firstPost.lowerBound)
        #expect(primitive.contains("postPreparedEvent(\n                primerDown"))
        #expect(primitive.contains("postPreparedEvent(\n            primerUp"))
        #expect(primitive.contains("postPreparedEvent(\n            targetDown"))
        #expect(primitive.contains("postPreparedEvent(\n            targetUp"))
        #expect(!primitive.contains("performAutoSend("))
        #expect(!primitive.contains("AXUIElementPerformAction"))
        #expect(!primitive.contains("postToPid("))
        #expect(!primitive.contains("post(tap:"))
    }

    @Test func targetedTelegramHIDReturnMatchesProvenPublicSequence() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paster = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Paste/CursorPaster.swift"
            ),
            encoding: .utf8
        )
        let primitiveStart = try #require(paster.range(
            of: "    static func performTargetedTelegramHIDReturn("
        ))
        let primitiveEnd = try #require(paster.range(
            of: "    // MARK: - Auto Send Keys",
            range: primitiveStart.upperBound..<paster.endIndex
        ))
        let primitive = paster[
            primitiveStart.lowerBound..<primitiveEnd.lowerBound
        ]

        #expect(primitive.contains(
            "CGEventSource(stateID: .hidSystemState)"
        ))
        #expect(primitive.contains("modifiersBegan.type = .flagsChanged"))
        #expect(primitive.contains("keyDown.postToPid(targetPID)"))
        #expect(primitive.contains("keyUp.postToPid(targetPID)"))
        #expect(primitive.contains("modifiersEnded.type = .flagsChanged"))
        #expect(primitive.contains(
            "CGEventSource.flagsState(.combinedSessionState)"
        ))
        #expect(primitive.contains("modifiersEnded.postToPid(targetPID)"))
        #expect(primitive.contains("mach_absolute_time()"))
        #expect(primitive.contains("guard canPost() else"))
        #expect(!primitive.contains("post(tap:"))
        #expect(!primitive.contains("await wait"))
        #expect(!primitive.contains("SLEvent"))
        #expect(!primitive.contains("beginTargetedInputSession"))
    }

    @MainActor
    @Test func semanticSendFinalGateRejectsStopAndUnauditedUnlabelledButtons() {
        var actionCount = 0
        func attempt(
            label: String?,
            allowsAuditedUnlabelledSend: Bool,
            labelWasReadable: Bool = true
        ) -> FocusLockService.NearbySubmitButtonResult {
            FocusLockService.performProvenSemanticSend(
                isUnambiguous: true,
                pidMatches: true,
                windowMatches: true,
                geometryMatches: true,
                roleMatches: true,
                enabled: true,
                label: label,
                labelWasReadable: labelWasReadable,
                allowsAuditedUnlabelledSend: allowsAuditedUnlabelledSend,
                hasPressAction: true,
                boundaryMatches: true,
                action: {
                    actionCount += 1
                    return 0
                }
            )
        }

        #expect(attempt(label: "Stop", allowsAuditedUnlabelledSend: true) == .unavailable)
        #expect(attempt(label: nil, allowsAuditedUnlabelledSend: false) == .unavailable)
        #expect(attempt(
            label: nil,
            allowsAuditedUnlabelledSend: true,
            labelWasReadable: false
        ) == .unavailable)
        #expect(actionCount == 0)
        #expect(attempt(label: "Send", allowsAuditedUnlabelledSend: false) == .pressed)
        #expect(actionCount == 1)
        #expect(attempt(label: nil, allowsAuditedUnlabelledSend: true) == .pressed)
        #expect(actionCount == 2)
    }

    @MainActor
    @Test func CodexTraversalMergesNavigationVisibleAndOrdinaryChildren() {
        #expect(FocusLockService.mergedTraversalChildren(
            visible: [1],
            ordinary: [2],
            navigationOrder: [3],
            areEquivalent: { $0 == $1 }
        ) == [3, 1, 2])
        #expect(FocusLockService.mergedTraversalChildren(
            visible: [],
            ordinary: [2],
            navigationOrder: [3, 2],
            areEquivalent: { $0 == $1 }
        ) == [3, 2])
        #expect(FocusLockService.mergedTraversalChildren(
            visible: [2, 3],
            ordinary: [1, 3],
            navigationOrder: [3, 2],
            areEquivalent: { $0 == $1 }
        ) == [3, 2, 1])
    }

    @MainActor
    @Test func semanticSendGeometryRejectsRemoteButtons() {
        let editor = CGRect(x: 100, y: 100, width: 600, height: 100)
        #expect(FocusLockService.semanticSendGeometryMatches(
            editorFrame: editor,
            candidateFrame: CGRect(x: 650, y: 150, width: 32, height: 32)
        ))
        #expect(!FocusLockService.semanticSendGeometryMatches(
            editorFrame: editor,
            candidateFrame: CGRect(x: 1_500, y: 900, width: 32, height: 32)
        ))
    }

    @MainActor
    @Test func deferredForegroundAutoSendNeverReactivatesAnExactInput() {
        #expect(TranscriptionDelivery.deferredForegroundAutoSendRoute(
            hasExactInput: true,
            exactInputOwnsKeyboardFocus: true,
            targetIsFrontmost: true
        ) == .foregroundExactInput)
        #expect(TranscriptionDelivery.deferredForegroundAutoSendRoute(
            hasExactInput: true,
            exactInputOwnsKeyboardFocus: false,
            targetIsFrontmost: false
        ) == .nonActivatingExactInput)
        #expect(TranscriptionDelivery.deferredForegroundAutoSendRoute(
            hasExactInput: true,
            exactInputOwnsKeyboardFocus: false,
            targetIsFrontmost: true
        ) == .foregroundExactInput)
        #expect(TranscriptionDelivery.deferredForegroundAutoSendRoute(
            hasExactInput: true,
            exactInputOwnsKeyboardFocus: true,
            targetIsFrontmost: false
        ) == .foregroundExactInput)
        #expect(TranscriptionDelivery.deferredForegroundAutoSendRoute(
            hasExactInput: false,
            exactInputOwnsKeyboardFocus: false,
            targetIsFrontmost: false
        ) == .failClosed)
        #expect(TranscriptionDelivery.deferredForegroundAutoSendRoute(
            hasExactInput: false,
            exactInputOwnsKeyboardFocus: false,
            targetIsFrontmost: true
        ) == .foregroundExactInput)
    }

    @Test func foregroundDeliveryRemainsAwaitedInsideSerializedPipeline() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/TranscriptionDelivery.swift"
            ),
            encoding: .utf8
        )
        let pasteStart = try #require(source.range(of: "    private func paste("))
        let backgroundStart = try #require(source.range(
            of: "    private func deliverToBackgroundExactInput(",
            range: pasteStart.upperBound..<source.endIndex
        ))
        let pasteBody = source[pasteStart.lowerBound..<backgroundStart.lowerBound]

        #expect(pasteBody.contains("let pasteResult = await pasteTask.value"))
        #expect(pasteBody.contains("defer { FocusLockService.shared.clearLock() }"))
        #expect(!pasteBody.contains("waitForForegroundInsertion"))
        #expect(!pasteBody.contains("Task { @MainActor in"))
    }

    @Test func realtimeStreamingRemainsRecorderHUDOnlyUntilFinalDelivery() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let draftWriter = repositoryRoot.appendingPathComponent(
            "VoiceInk/Transcription/Engine/RealtimeInputDraftSession.swift"
        )
        #expect(!FileManager.default.fileExists(atPath: draftWriter.path))

        let engineSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/VoiceInkEngine.swift"
            ),
            encoding: .utf8
        )
        #expect(engineSource.contains("session.partialTranscript = partial"))
        #expect(!engineSource.contains("realtimeInputDraft"))
        let partialCallbackStart = try #require(engineSource.range(
            of: "onPartialTranscript: {"
        ))
        let partialCallbackEnd = try #require(engineSource.range(
            of: "session.transcriptionSession = streamingSession",
            range: partialCallbackStart.upperBound..<engineSource.endIndex
        ))
        let partialCallback = String(
            engineSource[partialCallbackStart.lowerBound..<partialCallbackEnd.lowerBound]
        )
        #expect(!partialCallback.contains("delivery.deliver"))
        #expect(!partialCallback.contains("CursorPaster"))
        #expect(!partialCallback.contains("FocusLockService"))
        #expect(!partialCallback.contains("AXSelectedText"))

        let miniRecorderSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Views/Recorder/MiniRecorderView.swift"
            ),
            encoding: .utf8
        )
        let notchRecorderSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Views/Recorder/NotchRecorderView.swift"
            ),
            encoding: .utf8
        )
        #expect(miniRecorderSource.contains(
            "stateProvider.showsRealtimeTranscriptHUD"
        ))
        #expect(notchRecorderSource.contains(
            "stateProvider.showsRealtimeTranscriptHUD"
        ))
        #expect(miniRecorderSource.contains(
            "LiveTranscriptView(text: liveTranscriptDisplayText)"
        ))
        #expect(notchRecorderSource.contains(
            "LiveTranscriptView(text: liveTranscriptDisplayText)"
        ))

        let deliverySource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/TranscriptionDelivery.swift"
            ),
            encoding: .utf8
        )
        #expect(!deliverySource.contains("realtimeInputDraft"))

        let pipelineSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/TranscriptionPipeline.swift"
            ),
            encoding: .utf8
        )
        #expect(pipelineSource.components(
            separatedBy: "await delivery.deliver("
        ).count - 1 == 1)
        #expect(pipelineSource.contains(
            "text: finalText"
        ))
    }

    @Test func emptyRealtimeFinalFallsBackInsteadOfDeliveringBlankText() {
        #expect(StreamingFinalTextDisposition.resolve("") == .useBatchFallback)
        #expect(StreamingFinalTextDisposition.resolve(" \n\t") == .useBatchFallback)
        #expect(StreamingFinalTextDisposition.resolve("finished words") == .deliver("finished words"))
    }

    @Test func primaryDeliveryUsesOnlyBaseVoiceInkSystemFocusedCommands() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let deliverySource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/TranscriptionDelivery.swift"
            ),
            encoding: .utf8
        )
        let primaryStart = try #require(deliverySource.range(
            of: "    private func deliverPrimaryToCurrentSystemInput("
        ))
        let pasteStart = try #require(deliverySource.range(of: "    private func paste("))
        let backgroundStart = try #require(deliverySource.range(
            of: "    private func deliverToBackgroundExactInput(",
            range: primaryStart.upperBound..<deliverySource.endIndex
        ))
        let pasteBody = deliverySource[pasteStart.lowerBound..<primaryStart.lowerBound]
        #expect(pasteBody.contains("if target.destination.usesBaseCurrentInputDelivery"))
        #expect(pasteBody.contains("await deliverPrimaryToCurrentSystemInput("))
        #expect(pasteBody.contains("target.destination.usesAppSpecificExactDelivery"))
        let primaryRoute = try #require(pasteBody.range(
            of: "if target.destination.usesBaseCurrentInputDelivery"
        ))
        let exactRoute = try #require(pasteBody.range(
            of: "target.destination.usesAppSpecificExactDelivery"
        ))
        #expect(primaryRoute.lowerBound < exactRoute.lowerBound)

        let primaryBody = deliverySource[
            primaryStart.lowerBound..<backgroundStart.lowerBound
        ]

        #expect(primaryBody.contains("startPasteAtCursor(pastedText)"))
        #expect(primaryBody.contains(
            "Self.primaryCurrentInputSettleNanoseconds"
        ))
        #expect(primaryBody.contains("method: .cgEvent"))
        #expect(primaryBody.contains("verification=notRequired"))
        #expect(!primaryBody.contains("focusedInput"))
        #expect(!primaryBody.contains("foregroundAutoSendMethod"))
        #expect(!primaryBody.contains("await performAutoSend("))
        #expect(!primaryBody.contains("prepareBackgroundDelivery"))
        #expect(!primaryBody.contains("deliverToBackgroundExactInput"))
        #expect(!primaryBody.contains("verifyAndRetry"))
        #expect(!primaryBody.contains("telegramTargetedHIDReturn"))
        #expect(!primaryBody.contains("pressNearbySubmitButton"))
        #expect(!primaryBody.contains("foregroundOpenAIVerificationContext"))
        #expect(deliverySource.contains(
            "primaryCurrentInputSettleNanoseconds: UInt64 = 100_000_000"
        ))

        let engineSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/VoiceInkEngine.swift"
            ),
            encoding: .utf8
        )
        let primaryStopStart = try #require(engineSource.range(
            of: "            case .primaryCurrentInput:"
        ))
        let secondChanceStart = try #require(engineSource.range(
            of: "            case .focusedDuringTranscription:",
            range: primaryStopStart.upperBound..<engineSource.endIndex
        ))
        let primaryStopBody = engineSource[
            primaryStopStart.lowerBound..<secondChanceStart.lowerBound
        ]
        #expect(primaryStopBody.contains("focusedInput: nil"))
        #expect(!primaryStopBody.contains("captureFocusedInput"))
        #expect(!primaryStopBody.contains("modeSnapshot"))
        #expect(!primaryStopBody.contains("prepareBackgroundDelivery"))

        let pipelineSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/TranscriptionPipeline.swift"
            ),
            encoding: .utf8
        )
        #expect(pipelineSource.contains(
            "pasteTargetForDelivery.resolvedAutoSendKey("
        ))
    }

    @MainActor
    @Test func exactForegroundAutoSendUsesSurfaceSpecificHandlingAndBoundsHIDRetry() throws {
        #expect(TranscriptionDelivery.foregroundAutoSendMethod(
            bundleIdentifier: "com.openai.codex",
            autoSendKey: .enter
        ) == .systemEvents)
        #expect(TranscriptionDelivery.foregroundAutoSendMethod(
            bundleIdentifier: "com.openai.chat",
            autoSendKey: .enter
        ) == .systemEvents)
        #expect(TranscriptionDelivery.foregroundAutoSendMethod(
            bundleIdentifier: "ru.keepcoder.Telegram",
            autoSendKey: .enter
        ) == .cgEvent)
        #expect(TranscriptionDelivery.foregroundAutoSendMethod(
            bundleIdentifier: "com.openai.codex",
            autoSendKey: .shiftEnter
        ) == .cgEvent)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/TranscriptionDelivery.swift"
            ),
            encoding: .utf8
        )
        let autoSendStart = try #require(source.range(
            of: "    private func performAutoSend("
        ))
        let feedbackStart = try #require(source.range(
            of: "    private func showAutoSendFailure(",
            range: autoSendStart.upperBound..<source.endIndex
        ))
        let autoSendBody = source[autoSendStart.lowerBound..<feedbackStart.lowerBound]

        #expect(autoSendBody.contains("foregroundAutoSendMethod"))
        #expect(autoSendBody.contains("method: sendMethod"))
        #expect(autoSendBody.contains("verification=pending"))
        #expect(autoSendBody.contains("verifyAndRetryForegroundOpenAIReturn"))
        #expect(autoSendBody.contains("case .actionGuardRefused:"))
        #expect(autoSendBody.contains("return .needsNonActivatingExactInput"))
        #expect(autoSendBody.contains("foregroundOpenAIVerificationContext"))
        #expect(!autoSendBody.contains("pressNearbySubmitButton"))
        #expect(!autoSendBody.contains("performAuthenticatedTargetedReturn"))
        #expect(autoSendBody.contains("method: .cgEvent"))
    }

    @Test func autoSendFailureWarningStaysVisibleButSilent() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let deliverySource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/TranscriptionDelivery.swift"
            ),
            encoding: .utf8
        )
        let failureStart = try #require(deliverySource.range(
            of: "    private func showAutoSendFailure("
        ))
        let nextFunction = try #require(deliverySource.range(
            of: "    private func handleMissingPasteTarget(",
            range: failureStart.upperBound..<deliverySource.endIndex
        ))
        let failureBody = deliverySource[
            failureStart.lowerBound..<nextFunction.lowerBound
        ]

        #expect(failureBody.contains("type: .error"))
        #expect(failureBody.contains("playSound: false"))

        let notificationSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Notifications/NotificationManager.swift"
            ),
            encoding: .utf8
        )
        #expect(notificationSource.contains("playSound: Bool = true"))
        #expect(notificationSource.contains("if type == .error && playSound"))
    }

    @MainActor
    @Test func secondChanceRetargetCarriesAutoSendUntilDeliveryResolvesIt() async {
        let session = RecordingSession()
        let destinationMode = ModeConfig(
            name: "Codex destination",
            isAIEnhancementEnabled: true,
            isTextFormattingEnabled: true,
            outputMode: .paste,
            autoSendKey: .enter
        )
        let retargeted = RecordingPasteTarget(
            destination: .focusedDuringTranscription,
            focusedInput: nil,
            mode: destinationMode
        )

        #expect(session.retargetPaste(to: retargeted))
        let acceptedPulse = session.iconActionPulse
        #expect(acceptedPulse?.icon == .lockedDestination)
        #expect(session.lockedDestinationIconActionPulseID == acceptedPulse?.id)
        #expect(session.currentFocusIconActionPulseID == nil)
        let resolvedTarget = await session.resolvePasteTargetForDelivery()
        #expect(resolvedTarget.destination == .focusedDuringTranscription)
        #expect(resolvedTarget.autoSendKey == .enter)
        #expect(resolvedTarget.mode == destinationMode)
        #expect(resolvedTarget.mode?.isAIEnhancementEnabled == true)
        #expect(resolvedTarget.mode?.isTextFormattingEnabled == true)
        #expect(!session.retargetPaste(to: RecordingPasteTarget(destination: .recordingStart, focusedInput: nil)))
        #expect(session.pasteTarget.destination == .focusedDuringTranscription)
        #expect(session.iconActionPulse == acceptedPulse)
    }

    @MainActor
    @Test func terminalAutomationIdentityRequiresExactWindowAndTTYPair() {
        let capturedContents =
            "stable Claude Code output line long enough\n$ ready\n"
        let encodedCapture =
            "8123\n/dev/ttys004\n2\n\(capturedContents.count)\n"
            + capturedContents + "\n"
        #expect(
            FocusLockService.terminalCaptureScriptResult(encodedCapture)
                == FocusLockService.TerminalCaptureScriptResult(
                    windowID: 8123,
                    sessionIdentity: "/dev/ttys004",
                    siblingSessionCount: 2,
                    contents: capturedContents
                )
        )
        #expect(FocusLockService.terminalCaptureScriptResult(
            "not-a-window\n/dev/ttys004\n2\n\(capturedContents.count)\n"
                + capturedContents
        ) == nil)
        #expect(FocusLockService.terminalCaptureScriptResult(
            "8123\n/dev/ttys004\n0\n\(capturedContents.count)\n"
                + capturedContents
        ) == nil)

        let anchors = FocusLockService.terminalContentAnchors(
            """
            stable Claude Code output line long enough
            another distinctive terminal line for identity
            """
        )
        #expect(FocusLockService.terminalDecisionFingerprintMatches(
            captured: anchors,
            native: anchors
                + ["new terminal output line after the recording began"],
            siblingSessionCount: 2
        ))
        #expect(!FocusLockService.terminalDecisionFingerprintMatches(
            captured: anchors,
            native: ["different terminal session content entirely"],
            siblingSessionCount: 2
        ))
        #expect(FocusLockService.terminalDecisionFingerprintMatches(
            captured: [],
            native: [],
            siblingSessionCount: 1
        ))
        #expect(!FocusLockService.terminalDecisionFingerprintMatches(
            captured: [],
            native: [],
            siblingSessionCount: 2
        ))

        let before = "$ ready "
        let after = "$ ready become jarvis\n"
        let encodedDelivery =
            "8123\n/dev/ttys004\n\(before.count)\n\(after.count)\n"
            + before + after + "\n"
        #expect(
            FocusLockService.terminalNativeScriptResult(encodedDelivery)
                == FocusLockService.TerminalNativeScriptResult(
                    windowID: 8123,
                    sessionIdentity: "/dev/ttys004",
                    previousContents: before,
                    currentContents: after
                )
        )
        #expect(FocusLockService.terminalNativeScriptResult(
            "8124\n/dev/ttys999\n4\n9999\nshort"
        ) == nil)
    }

    @MainActor
    @Test func nativeTerminalDeliveryRequiresNewTextAndPromptTransition() {
        #expect(TranscriptionDelivery.classifyNativeTerminalDelivery(
            from: "$ ready ",
            to: "$ ready become jarvis\nresponse",
            insertedText: "become jarvis"
        ) == .verified)
        #expect(TranscriptionDelivery.classifyNativeTerminalDelivery(
            from: "$ ready ",
            to: "$ ready become jarvis",
            insertedText: "become jarvis"
        ) == .modifiedWithoutSubmit)
        #expect(TranscriptionDelivery.classifyNativeTerminalDelivery(
            from: "$ ready ",
            to: "$ ready ",
            insertedText: "become jarvis"
        ) == .unchanged)
        #expect(TranscriptionDelivery.classifyNativeTerminalDelivery(
            from: "old become jarvis\n$ ready ",
            to: "repainted Claude TUI without a shared buffer boundary",
            insertedText: "become jarvis"
        ) == .unreadable)
        #expect(FocusLockService.terminalTextIsSafeForSingleNativeOperation(
            "become jarvis"
        ))
        #expect(!FocusLockService.terminalTextIsSafeForSingleNativeOperation(
            "first command\nsecond command"
        ))
    }

    @MainActor
    @Test func terminalAppleScriptTransportIsAtomicBoundedAndNextOnly() throws {
        let plain = FocusLockService.appleScriptLiteral("plain")
        let controls = FocusLockService.appleScriptLiteral("a\nb\r\tc")
        let quotesAndSlash = FocusLockService.appleScriptLiteral(
            "say \"hi\" \\ now"
        )
        #expect(plain == "\"plain\"")
        #expect(
            controls
                == "\"a\" & (ASCII character 10) & \"b\" & (ASCII character 13) & (ASCII character 9) & \"c\""
        )
        #expect(quotesAndSlash == "\"say \\\"hi\\\" \\\\ now\"")

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let focusSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Modes/FocusLockService.swift"
            ),
            encoding: .utf8
        )
        let nativeStart = try #require(focusSource.range(
            of: "    func performTerminalTextDelivery("
        ))
        let nativeEnd = try #require(focusSource.range(
            of: "    func backgroundDeliveryBoundaryMatches(",
            range: nativeStart.upperBound..<focusSource.endIndex
        ))
        let nativeBody = focusSource[
            nativeStart.lowerBound..<nativeEnd.lowerBound
        ]
        #expect(nativeBody.components(separatedBy: "do script").count - 1 == 1)
        #expect(nativeBody.contains("autoSendKey == .enter"))
        #expect(nativeBody.contains("terminalAutomationTarget"))
        #expect(!nativeBody.contains("typeTextIntoPreparedTargetedProcess"))
        #expect(!nativeBody.contains("performAutoSend"))

        let deliverySource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/TranscriptionDelivery.swift"
            ),
            encoding: .utf8
        )
        let exactStart = try #require(deliverySource.range(
            of: "    private func deliverToBackgroundExactInput("
        ))
        let exactEnd = try #require(deliverySource.range(
            of: "    private func deliverToNativeTerminalSession(",
            range: exactStart.upperBound..<deliverySource.endIndex
        ))
        let exactPrefix = deliverySource[
            exactStart.lowerBound..<exactEnd.lowerBound
        ]
        let terminalBranch = try #require(exactPrefix.range(
            of: "requiresNativeTerminalSessionBinding"
        ))
        let genericRead = try #require(exactPrefix.range(
            of: "backgroundInputText("
        ))
        #expect(terminalBranch.lowerBound < genericRead.lowerBound)

        let primaryStart = try #require(deliverySource.range(
            of: "    private func deliverPrimaryToCurrentSystemInput("
        ))
        let primaryEnd = try #require(deliverySource.range(
            of: "    private func deliverToBackgroundExactInput(",
            range: primaryStart.upperBound..<deliverySource.endIndex
        ))
        let primaryBody = deliverySource[
            primaryStart.lowerBound..<primaryEnd.lowerBound
        ]
        #expect(!primaryBody.contains("Terminal"))
        #expect(!primaryBody.contains("AppleScript"))
        #expect(!primaryBody.contains("terminalNativeAtomic"))

        let runnerSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Services/BoundedAppleScriptRunner.swift"
            ),
            encoding: .utf8
        )
        #expect(runnerSource.contains("process.arguments = [\"-\"]"))
        #expect(runnerSource.contains("SIGKILL"))
        #expect(!runnerSource.contains("do shell script"))
    }

    @Test func boundedAppleScriptErrorsNeverExposeTerminalDiagnostics() {
        let secret = "SyntheticPrivateTranscriptAndTTY"
        let error = BoundedAppleScriptError.redactedNonZeroExit(
            status: 17,
            untrustedStderr: "Terminal rejected \(secret)"
        )
        #expect(error.localizedDescription == "osascript exited with status 17")
        #expect(!error.localizedDescription.contains(secret))
    }

    @Test func boundedAppleScriptRunnerKillsTimedOutHelper() async {
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await BoundedAppleScriptRunner.run(
                source: "delay 5",
                timeout: 0.1
            )
            Issue.record("Expected the delayed AppleScript helper to time out")
        } catch let error as BoundedAppleScriptError {
            guard case .timeout(let seconds) = error else {
                Issue.record("Unexpected bounded AppleScript error: \(error)")
                return
            }
            #expect(seconds == 0.1)
        } catch {
            Issue.record("Unexpected AppleScript runner error: \(error)")
        }

        #expect(ProcessInfo.processInfo.systemUptime - startedAt < 2.0)
    }

    @Test func appleScriptPasteUsesTheBoundedOffMainRunner() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paster = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Paste/CursorPaster.swift"
            ),
            encoding: .utf8
        )
        let start = try #require(paster.range(
            of: "    private static func pasteUsingAppleScript() async -> Bool {"
        ))
        let end = try #require(paster.range(
            of: "    // MARK: - CGEvent paste",
            range: start.upperBound..<paster.endIndex
        ))
        let body = paster[start.lowerBound..<end.lowerBound]

        #expect(body.contains("BoundedAppleScriptRunner.run("))
        #expect(body.contains("timeout: appleScriptPasteTimeout"))
        #expect(!body.contains("executeAndReturnError"))
        #expect(!body.contains("NSAppleScript"))
    }

    @MainActor
    @Test func recorderIconPulseMapsPrimaryAndNextRoutesToSeparateIcons() {
        let session = RecordingSession()

        session.signalDestinationAction(.primaryCurrentInput)
        let primaryPulse = session.iconActionPulse
        #expect(primaryPulse?.icon == .currentFocus)
        #expect(session.currentFocusIconActionPulseID == primaryPulse?.id)
        #expect(session.lockedDestinationIconActionPulseID == nil)

        session.signalDestinationAction(.recordingStart)
        let nextPulse = session.iconActionPulse
        #expect(nextPulse?.icon == .lockedDestination)
        #expect(nextPulse?.id != primaryPulse?.id)
        #expect(session.currentFocusIconActionPulseID == nil)
        #expect(session.lockedDestinationIconActionPulseID == nextPulse?.id)
    }

    @MainActor
    @Test func neutralPasteTargetModeDoesNotFallBackToCurrentMode() {
        let formatting = ModeRuntimeResolver.pasteTargetTranscriptionFormattingConfiguration(
            mode: nil
        )
        let output = ModeRuntimeResolver.pasteTargetOutputConfiguration(mode: nil)

        #expect(formatting.mode == nil)
        #expect(output.mode == nil)
        #expect(output.outputMode == .paste)
        #expect(output.autoSendKey == .none)
        #expect(output.customCommand == nil)
    }

    @MainActor
    @Test func explicitTriggerWordModeOverridesDestinationWithoutReadingGlobalMode() {
        let session = RecordingSession()
        let destinationMode = ModeConfig(
            name: "Destination",
            isAIEnhancementEnabled: false,
            autoSendKey: .enter
        )
        let triggerMode = ModeConfig(
            name: "Explicit trigger",
            isAIEnhancementEnabled: true,
            outputMode: .respond
        )

        #expect(session.retargetPaste(to: RecordingPasteTarget(
            destination: .focusedDuringTranscription,
            focusedInput: nil,
            mode: destinationMode
        )))
        session.applyTriggerWordModeOverride(triggerMode)

        #expect(session.postProcessingMode == triggerMode)
        #expect(session.pasteTarget.autoSendKey == .enter)
    }

    @MainActor
    @Test func exactInputContextFingerprintFailsClosedAcrossDifferentDocuments() {
        let captured = ["unique original task prompt", "stable original response"]

        #expect(FocusLockService.contextFingerprintMatches(
            captured: captured,
            current: ["stable original response", "unique original task prompt", "new reply"]
        ))
        #expect(!FocusLockService.contextFingerprintMatches(
            captured: captured,
            current: ["unique original task prompt", "different task response"]
        ))
        #expect(!FocusLockService.contextFingerprintMatches(
            captured: captured,
            current: []
        ))
    }

    @Test func dailyUpdatePolicyIsDefaultOnBoundedAndNotificationOnly() throws {
        let defaultsSource = try repositorySource("VoiceInk/AppDefaults.swift")
        let appSource = try repositorySource("VoiceInk/VoiceInk.swift")
        let settingsSource = try repositorySource(
            "VoiceInk/Views/Settings/SettingsView.swift"
        )

        #expect(defaultsSource.contains(
            "\"VIPPDailyUpdateChecksEnabled\": true"
        ))
        #expect(
            VoiceInkUpdatePolicy.automaticCheckInterval == 24 * 60 * 60
        )
        #expect(VoiceInkUpdatePolicy.isAutomaticCheckDue(
            lastCheck: nil,
            now: Date(timeIntervalSince1970: 100_000)
        ))
        #expect(!VoiceInkUpdatePolicy.isAutomaticCheckDue(
            lastCheck: Date(timeIntervalSince1970: 100_000),
            now: Date(timeIntervalSince1970: 100_000 + 86_399)
        ))
        #expect(VoiceInkUpdatePolicy.isAutomaticCheckDue(
            lastCheck: Date(timeIntervalSince1970: 100_000),
            now: Date(timeIntervalSince1970: 100_000 + 86_400)
        ))

        #expect(appSource.contains(
            "https://api.github.com/repos/Beingpax/VoiceInk/releases/latest"
        ))
        #expect(appSource.contains("There’s a VoiceInk update"))
        #expect(!appSource.contains("SPUStandardUpdaterController"))
        #expect(!appSource.contains("updaterController.checkForUpdates"))
        #expect(settingsSource.contains("Daily VoiceInk Update Checks"))
        #expect(settingsSource.contains(
            "never installs or merges upstream updates automatically"
        ))
    }

    @Test func dailyUpdateNotificationDeduplicatesNewUpstreamReleases() {
        #expect(VoiceInkUpdatePolicy.isNewerRelease(
            "v2.0.1",
            than: "v2.0"
        ))
        #expect(VoiceInkUpdatePolicy.isNewerRelease(
            "V2.1",
            than: "2.0.9"
        ))
        #expect(!VoiceInkUpdatePolicy.isNewerRelease(
            "v2.0",
            than: "2.0"
        ))
        #expect(!VoiceInkUpdatePolicy.isNewerRelease(
            "v1.99",
            than: "v2.0"
        ))
        #expect(VoiceInkUpdatePolicy.shouldNotify(
            releaseTag: "v2.1",
            integratedUpstreamTag: "v2.0",
            lastNotifiedTag: nil,
            checksEnabled: true
        ))
        #expect(!VoiceInkUpdatePolicy.shouldNotify(
            releaseTag: "v2.1",
            integratedUpstreamTag: "v2.0",
            lastNotifiedTag: "v2.1",
            checksEnabled: true
        ))
        #expect(!VoiceInkUpdatePolicy.shouldNotify(
            releaseTag: "v2.1",
            integratedUpstreamTag: "v2.0",
            lastNotifiedTag: nil,
            checksEnabled: false
        ))
    }

    @Test func mainWindowFirstRunPlacementUsesTopRightOfChosenScreen() {
        let frame = WindowManager.topRightFrame(
            windowFrame: NSRect(x: 0, y: 0, width: 400, height: 300),
            visibleFrame: NSRect(x: 100, y: 200, width: 1_200, height: 800)
        )

        #expect(frame == NSRect(x: 876, y: 676, width: 400, height: 300))
    }

    @Test func mainWindowPlacementPersistsWithOneStableFrameName() throws {
        let source = try repositorySource("VoiceInk/WindowManager.swift")

        #expect(source.contains(
            "window.setFrameUsingName(Self.mainWindowAutosaveName)"
        ))
        #expect(source.contains(
            "window.saveFrame(usingName: Self.mainWindowAutosaveName)"
        ))
        #expect(source.contains("func windowDidMove"))
        #expect(source.contains("func windowDidResize"))
        #expect(source.contains("func windowDidChangeScreen"))
        #expect(!source.contains("window.center()"))
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

}

import Foundation
import Testing
@testable import VoiceInkPlusPlus

private actor FakeChatGPTVoiceMuteTransport: ChatGPTVoiceMuteTransport {
    var currentSnapshot: ChatGPTVoiceInputSnapshot?
    var allowsPost = true
    var changesStateOnPost = true
    var postPIDs: [pid_t] = []

    init(snapshot: ChatGPTVoiceInputSnapshot?) {
        currentSnapshot = snapshot
    }

    func snapshot() async -> ChatGPTVoiceInputSnapshot? {
        currentSnapshot
    }

    func postMicrophoneToggle(to applicationPID: pid_t) async -> Bool {
        postPIDs.append(applicationPID)
        guard allowsPost else { return false }
        if changesStateOnPost,
           let currentSnapshot,
           currentSnapshot.applicationPID == applicationPID {
            self.currentSnapshot = ChatGPTVoiceInputSnapshot(
                applicationPID: applicationPID,
                isInputRunning: !currentSnapshot.isInputRunning
            )
        }
        return true
    }

    func waitForInputState(
        _ isInputRunning: Bool,
        applicationPID: pid_t
    ) async -> Bool {
        currentSnapshot == ChatGPTVoiceInputSnapshot(
            applicationPID: applicationPID,
            isInputRunning: isInputRunning
        )
    }

    func setSnapshot(_ snapshot: ChatGPTVoiceInputSnapshot?) {
        currentSnapshot = snapshot
    }

    func setAllowsPost(_ allowsPost: Bool) {
        self.allowsPost = allowsPost
    }

    func setChangesStateOnPost(_ changesStateOnPost: Bool) {
        self.changesStateOnPost = changesStateOnPost
    }

    func postedPIDs() -> [pid_t] {
        postPIDs
    }
}

struct ChatGPTVoiceCaptureMuteCoordinatorTests {
    private let pid: pid_t = 4_242

    @Test func activeVoiceIsMutedAndOwnedThenRestored() async {
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: .init(
            applicationPID: pid,
            isInputRunning: true
        ))
        let coordinator = makeCoordinator(transport)

        await coordinator.setCaptureActive(true)
        await coordinator.waitForPendingTransitionsForTesting()
        var state = await coordinator.stateForTesting()
        #expect(state.captureActive)
        #expect(state.ownedMutedApplicationPID == pid)
        var postPIDs = await transport.postedPIDs()
        #expect(postPIDs == [pid])

        await coordinator.setCaptureActive(false)
        await coordinator.waitForPendingTransitionsForTesting()
        state = await coordinator.stateForTesting()
        #expect(!state.captureActive)
        #expect(state.ownedMutedApplicationPID == nil)
        postPIDs = await transport.postedPIDs()
        let restoredSnapshot = await transport.snapshot()
        #expect(postPIDs == [pid, pid])
        #expect(restoredSnapshot?.isInputRunning == true)
    }

    @Test func absentOrAlreadyInactiveVoiceIsNeverToggledOrOwned() async {
        let absent = FakeChatGPTVoiceMuteTransport(snapshot: nil)
        let absentCoordinator = makeCoordinator(absent)
        await absentCoordinator.setCaptureActive(true)
        await absentCoordinator.waitForPendingTransitionsForTesting()
        let absentPostPIDs = await absent.postedPIDs()
        let absentState = await absentCoordinator.stateForTesting()
        #expect(absentPostPIDs.isEmpty)
        #expect(absentState.ownedMutedApplicationPID == nil)

        let inactive = FakeChatGPTVoiceMuteTransport(snapshot: .init(
            applicationPID: pid,
            isInputRunning: false
        ))
        let inactiveCoordinator = makeCoordinator(inactive)
        await inactiveCoordinator.setCaptureActive(true)
        await inactiveCoordinator.waitForPendingTransitionsForTesting()
        let inactivePostPIDs = await inactive.postedPIDs()
        let inactiveState = await inactiveCoordinator.stateForTesting()
        #expect(inactivePostPIDs.isEmpty)
        #expect(inactiveState.ownedMutedApplicationPID == nil)
    }

    @Test func unverifiedToggleNeverCreatesRestorationOwnership() async {
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: .init(
            applicationPID: pid,
            isInputRunning: true
        ))
        await transport.setChangesStateOnPost(false)
        let coordinator = makeCoordinator(transport)

        await coordinator.setCaptureActive(true)
        await coordinator.waitForPendingTransitionsForTesting()
        var postPIDs = await transport.postedPIDs()
        var state = await coordinator.stateForTesting()
        #expect(postPIDs == [pid])
        #expect(state.ownedMutedApplicationPID == nil)

        await coordinator.setCaptureActive(false)
        await coordinator.waitForPendingTransitionsForTesting()
        postPIDs = await transport.postedPIDs()
        state = await coordinator.stateForTesting()
        #expect(postPIDs == [pid])
        #expect(!state.captureActive)
    }

    @Test func userReenabledInputRelinquishesOwnershipWithoutInverseToggle() async {
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: .init(
            applicationPID: pid,
            isInputRunning: true
        ))
        let coordinator = makeCoordinator(transport)

        await coordinator.setCaptureActive(true)
        await coordinator.waitForPendingTransitionsForTesting()
        await transport.setSnapshot(.init(applicationPID: pid, isInputRunning: true))

        await coordinator.setCaptureActive(false)
        await coordinator.waitForPendingTransitionsForTesting()
        let state = await coordinator.stateForTesting()
        let postPIDs = await transport.postedPIDs()
        #expect(state.ownedMutedApplicationPID == nil)
        #expect(postPIDs == [pid])
    }

    @Test func pauseResumeAndRapidCyclesEndInTheNewestCaptureState() async {
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: .init(
            applicationPID: pid,
            isInputRunning: true
        ))
        let coordinator = makeCoordinator(transport)

        await coordinator.setCaptureActive(true)
        await coordinator.setCaptureActive(false)
        await coordinator.setCaptureActive(true)
        await coordinator.waitForPendingTransitionsForTesting()

        let state = await coordinator.stateForTesting()
        let postPIDs = await transport.postedPIDs()
        let snapshot = await transport.snapshot()
        #expect(state.captureActive)
        #expect(state.ownedMutedApplicationPID == pid)
        #expect(postPIDs == [pid, pid, pid])
        #expect(snapshot?.isInputRunning == false)
    }

    @Test func aChangedChatGPTProcessIsNeverRestored() async {
        let transport = FakeChatGPTVoiceMuteTransport(snapshot: .init(
            applicationPID: pid,
            isInputRunning: true
        ))
        let coordinator = makeCoordinator(transport)

        await coordinator.setCaptureActive(true)
        await coordinator.waitForPendingTransitionsForTesting()
        await transport.setSnapshot(.init(applicationPID: pid + 1, isInputRunning: false))
        await coordinator.setCaptureActive(false)
        await coordinator.waitForPendingTransitionsForTesting()

        let postPIDs = await transport.postedPIDs()
        let state = await coordinator.stateForTesting()
        #expect(postPIDs == [pid])
        #expect(state.ownedMutedApplicationPID == nil)
    }

    @Test func executableBoundaryRejectsCodexAndAcceptsOnlyChatGPTBundle() {
        #expect(SystemChatGPTVoiceMuteTransport.belongsToChatGPTApplication(
            "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
        ))
        #expect(SystemChatGPTVoiceMuteTransport.belongsToChatGPTApplication(
            "/Applications/ChatGPT.app/Contents/Frameworks/Codex (Service).app/Contents/MacOS/Codex (Service)"
        ))
        #expect(!SystemChatGPTVoiceMuteTransport.belongsToChatGPTApplication(
            "/Applications/Codex.app/Contents/MacOS/Codex"
        ))
        #expect(!SystemChatGPTVoiceMuteTransport.belongsToChatGPTApplication(
            "/private/tmp/ChatGPT.app/Contents/MacOS/ChatGPT"
        ))
    }

    @Test func shortcutBindingMustMatchTheExactSupportedCommandAndAccelerator() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keybindings.json")

        try Data(#"[{"command":"realtimeVoice.toggleMicrophoneMute","key":"Command+Control+Option+Shift+F20"}]"#.utf8)
            .write(to: file)
        #expect(SystemChatGPTVoiceMuteTransport.hasExpectedShortcutBinding(at: file))

        try Data(#"[{"command":"realtimeVoice.toggleOutputMute","key":"Command+Control+Option+Shift+F20"}]"#.utf8)
            .write(to: file)
        #expect(!SystemChatGPTVoiceMuteTransport.hasExpectedShortcutBinding(at: file))

        try Data(#"[{"command":"realtimeVoice.toggleMicrophoneMute","key":"Alt+M"}]"#.utf8)
            .write(to: file)
        #expect(!SystemChatGPTVoiceMuteTransport.hasExpectedShortcutBinding(at: file))
    }

    @Test func recorderHardwareCaptureOwnsTheLeaseAndNoTranscriptionOrNotifierPathDoes() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let recorder = try String(
            contentsOf: repositoryRoot.appendingPathComponent("VoiceInk/Recorder.swift"),
            encoding: .utf8
        )
        let notifier = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Notifications/RecordingActivityNotifier.swift"
            ),
            encoding: .utf8
        )
        let transcriptionDirectory = repositoryRoot.appendingPathComponent("VoiceInk/Transcription")
        let transcriptionSources = try FileManager.default
            .subpathsOfDirectory(atPath: transcriptionDirectory.path)
            .filter { $0.hasSuffix(".swift") }
            .map {
                try String(
                    contentsOf: transcriptionDirectory.appendingPathComponent($0),
                    encoding: .utf8
                )
            }
            .joined(separator: "\n")

        #expect(recorder.components(separatedBy:
            "ChatGPTVoiceCaptureMuteCoordinator.shared.setCaptureActive(true)"
        ).count - 1 == 2)
        #expect(recorder.components(separatedBy:
            "ChatGPTVoiceCaptureMuteCoordinator.shared.setCaptureActive(false)"
        ).count - 1 == 2)
        #expect(!notifier.contains("ChatGPTVoiceCaptureMuteCoordinator.shared"))
        #expect(!transcriptionSources.contains("ChatGPTVoiceCaptureMuteCoordinator"))
    }

    @Test func targetedShortcutCannotActivateChatGPTOrMoveThePointer() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Services/ChatGPTVoiceCaptureMuteCoordinator.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("keyDown.postToPid(applicationPID)"))
        #expect(source.contains("keyUp.postToPid(applicationPID)"))
        #expect(!source.contains(".activate(options:"))
        #expect(!source.contains("CGEvent(mouseEventSource:"))
        #expect(!source.contains("AXUIElement"))
        #expect(!source.contains("RecordingActivityNotifier.post"))
    }

    private func makeCoordinator(
        _ transport: FakeChatGPTVoiceMuteTransport
    ) -> ChatGPTVoiceCaptureMuteCoordinator {
        ChatGPTVoiceCaptureMuteCoordinator(
            transport: transport,
            ownershipPollNanoseconds: 60_000_000_000
        )
    }
}

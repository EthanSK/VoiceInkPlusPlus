import Foundation
import AppKit
import Carbon
import os

class CursorPaster {
    private typealias ClipboardItemSnapshot = [(NSPasteboard.PasteboardType, Data)]
    private typealias ClipboardSnapshot = [ClipboardItemSnapshot]
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CursorPaster")

    enum PasteResult: Equatable {
        case commandPosted
        case commandNotPosted

        var didPostPasteCommand: Bool {
            self == .commandPosted
        }
    }

    enum AutoSendResult: Equatable {
        case commandPosted
        case commandNotPosted

        var didPostAutoSendCommand: Bool {
            self == .commandPosted
        }
    }

    enum AutoSendMethod {
        case systemEvents
        case cgEvent
    }

    private static let prePasteDelay: TimeInterval = 0.10
    private static let pasteShortcutEventDelay: TimeInterval = 0.01
    private static let minimumClipboardRestoreDelay: TimeInterval = 0.25

    static func pasteAtCursor(_ text: String) {
        Task {
            let pasteTask = await MainActor.run {
                startPasteAtCursor(text)
            }
            _ = await pasteTask.value
        }
    }

    @MainActor
    @discardableResult
    static func startPasteAtCursor(
        _ text: String,
        preflight: (() -> Bool)? = nil
    ) -> Task<PasteResult, Never> {
        Task { @MainActor in
            await performPasteSession(
                text,
                preflight: preflight
            )
        }
    }

    @MainActor
    static func pasteAtCursorAndWaitUntilPosted(_ text: String) async -> PasteResult {
        await startPasteAtCursor(text).value
    }

    @MainActor
    private static func performPasteSession(
        _ text: String,
        preflight: (() -> Bool)?
    ) async -> PasteResult {
        let pasteboard = NSPasteboard.general
        let shouldRestoreClipboard = UserDefaults.standard.bool(forKey: "restoreClipboardAfterPaste")
        let savedContents = shouldRestoreClipboard ? snapshotClipboard(from: pasteboard) : []
        let sessionID = UUID().uuidString

        guard ClipboardManager.setClipboard(
            text,
            transient: shouldRestoreClipboard,
            sessionID: shouldRestoreClipboard ? sessionID : nil
        ) else {
            logger.error("Failed to prepare clipboard for paste")
            return .commandNotPosted
        }
        defer {
            if shouldRestoreClipboard {
                scheduleClipboardRestore(
                    savedContents,
                    expectedText: text,
                    sessionID: sessionID,
                    on: pasteboard
                )
            }
        }

        await wait(prePasteDelay)
        guard preflight?() != false else {
            // The user may click away during the deliberate clipboard-settlement wait.
            // Never let a global Cmd-V drift into that newly focused app; the caller can
            // retry through its frozen exact-input, non-activating delivery session.
            logger.notice("Cancelled foreground paste because its exact focus preflight changed before Cmd-V")
            return .commandNotPosted
        }

        let pasteResult = await postPasteCommand(
            preflight: preflight
        )
        return pasteResult
    }

    private static func snapshotClipboard(from pasteboard: NSPasteboard) -> ClipboardSnapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                if let data = item.data(forType: type) {
                    return (type, data)
                }
                return nil
            }
        }
    }

    @MainActor
    private static func postPasteCommand(
        preflight: (() -> Bool)?
    ) async -> PasteResult {
        if PasteMethod.current() == .appleScript {
            return pasteUsingAppleScript(preflight: preflight)
                ? .commandPosted
                : .commandNotPosted
        } else {
            return await pasteFromClipboard(
                preflight: preflight
            )
        }
    }

    private static func scheduleClipboardRestore(
        _ savedContents: ClipboardSnapshot,
        expectedText: String,
        sessionID: String,
        on pasteboard: NSPasteboard
    ) {
        let delay = max(
            UserDefaults.standard.double(forKey: "clipboardRestoreDelay"),
            minimumClipboardRestoreDelay
        )

        Task { @MainActor in
            await wait(delay)
            guard pasteboardStillOwnedByPasteSession(pasteboard, expectedText: expectedText, sessionID: sessionID) else {
                return
            }
            pasteboard.clearContents()
            if !savedContents.isEmpty {
                pasteboard.writeObjects(pasteboardItems(from: savedContents))
            }
        }
    }

    private static func pasteboardStillOwnedByPasteSession(
        _ pasteboard: NSPasteboard,
        expectedText: String,
        sessionID: String
    ) -> Bool {
        pasteboard.string(forType: .string) == expectedText &&
            pasteboard.string(forType: ClipboardManager.pasteSessionType) == sessionID
    }

    private static func pasteboardItems(from snapshot: ClipboardSnapshot) -> [NSPasteboardItem] {
        snapshot.map { itemSnapshot in
            let item = NSPasteboardItem()
            for (type, data) in itemSnapshot {
                item.setData(data, forType: type)
            }
            return item
        }
    }

    // MARK: - AppleScript paste

    // "X – QWERTY ⌘" layouts remap to QWERTY when Command is held, so keystroke "v" resolves
    // the wrong key code. key code 9 (physical V) bypasses layout translation for those layouts.
    private static func makeScript(_ source: String) -> NSAppleScript? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.compileAndReturnError(&error)
        return script
    }

    private static let pasteScriptKeystroke = makeScript("tell application \"System Events\" to keystroke \"v\" using command down")
    private static let pasteScriptKeyCode   = makeScript("tell application \"System Events\" to key code 9 using command down")
    private static let enterScript = makeScript("tell application \"System Events\" to key code 36")
    private static let shiftEnterScript = makeScript("tell application \"System Events\" to key code 36 using shift down")
    private static let commandEnterScript = makeScript("tell application \"System Events\" to key code 36 using command down")

    @MainActor
    private static var layoutSwitchesToQWERTYOnCommand: Bool {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let nameRef = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return false }
        return (Unmanaged<CFString>.fromOpaque(nameRef).takeUnretainedValue() as String).hasSuffix("⌘")
    }

    @MainActor
    private static func pasteUsingAppleScript(
        preflight: (() -> Bool)?
    ) -> Bool {
        guard let script = layoutSwitchesToQWERTYOnCommand ? pasteScriptKeyCode : pasteScriptKeystroke else {
            logger.error("AppleScript paste script is unavailable")
            return false
        }
        guard preflight?() != false else {
            logger.notice("Cancelled foreground AppleScript paste because its exact focus preflight changed immediately before Cmd-V")
            return false
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            logger.error("AppleScript paste failed: \(String(describing: error), privacy: .public)")
        }
        return error == nil
    }

    // MARK: - CGEvent paste

    // Posts Cmd+V via CGEvent without modifying the active input source.
    @MainActor
    private static func pasteFromClipboard(
        preflight: (() -> Bool)?
    ) async -> PasteResult {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required to paste with simulated key events")
            return .commandNotPosted
        }

        // Foreground Cmd-V deliberately uses private event state. Build 215 tried HID
        // state for OpenAI composers; its synthetic Command-down changed Electron's AX
        // wrapper before V-down, so the exact-input preflight correctly cancelled the
        // paste even though Ethan had not moved. Private state preserves both safety
        // checks without publishing an intermediate modifier state to the target app.
        let source = CGEventSource(stateID: .privateState)

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else {
            logger.error("Failed to create Cmd+V keyboard events")
            return .commandNotPosted
        }

        cmdDown.flags = .maskCommand
        vDown.flags   = .maskCommand
        vUp.flags     = .maskCommand

        guard preflight?() != false else {
            logger.notice("Cancelled foreground CGEvent paste because its exact focus preflight changed immediately before Command-down")
            return .commandNotPosted
        }

        cmdDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        guard preflight?() != false else {
            // Focus can move during the humanized Command-down/V-down interval. Release
            // Command but never post V: a global Cmd-V in Ethan's newly selected input
            // would be a wrong-target mutation, while a bare modifier release is safe.
            cmdUp.post(tap: .cghidEventTap)
            logger.notice("Cancelled foreground CGEvent paste and released Command because its exact focus preflight changed before V-down")
            return .commandNotPosted
        }
        vDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        vUp.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        cmdUp.post(tap: .cghidEventTap)

        return .commandPosted
    }

    private static func wait(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    // MARK: - Verified background exact-input delivery

    /// Electron ignores ordinary process-targeted keyboard events while inactive.
    /// A real background app transition delivers these two private AppKit state
    /// notifications first; the exact two-window Codex probe proved that reproducing
    /// them lets the app acknowledge its saved internal window/editor without becoming
    /// macOS frontmost. Callers still verify the AX window, AX editor, resulting text,
    /// and unchanged frontmost PID before treating any post as delivered.
    @MainActor
    static func beginTargetedInputSession(pid: pid_t) -> Bool {
        guard let keyFocusReturned = makeOtherEvent(
            typeRawValue: 21,
            subtypeRawValue: 0x8000
        ),
        let applicationActivated = makeOtherEvent(
            typeRawValue: NSEvent.EventType.appKitDefined.rawValue,
            subtypeRawValue: 1
        ) else {
            logger.error("Failed to create targeted input activation-state events pid=\(pid, privacy: .public)")
            return false
        }
        keyFocusReturned.postToPid(pid)
        applicationActivated.postToPid(pid)
        return true
    }

    @MainActor
    static func endTargetedInputSession(pid: pid_t) {
        makeOtherEvent(
            typeRawValue: NSEvent.EventType.appKitDefined.rawValue,
            subtypeRawValue: 2
        )?.postToPid(pid)
    }

    @MainActor
    static func typeTextIntoTargetedProcess(
        _ text: String,
        pid: pid_t,
        sessionAlreadyPrepared: Bool = false,
        beforeChunk: ((Int) -> Bool)? = nil
    ) async -> Bool {
        guard !text.isEmpty,
              AXIsProcessTrusted(),
              (sessionAlreadyPrepared || beginTargetedInputSession(pid: pid)) else {
            return false
        }
        defer {
            if !sessionAlreadyPrepared {
                endTargetedInputSession(pid: pid)
            }
        }

        let utf16 = Array(text.utf16)
        let source = CGEventSource(stateID: .hidSystemState)
        let completed = await runTargetedUnicodeChunks(
            utf16,
            beforeChunk: beforeChunk
        ) { chunk in
            guard let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false
            ) else {
                logger.error("Failed to create targeted Unicode keyboard events pid=\(pid, privacy: .public)")
                return false
            }

            chunk.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
            }
            keyDown.postToPid(pid)
            await wait(0.005)
            keyUp.postToPid(pid)
            await wait(0.005)
            return true
        }
        guard completed else {
            logger.error("Stopped targeted Unicode insertion because the exact input boundary changed or a chunk could not be posted pid=\(pid, privacy: .public)")
            return false
        }
        // The delivery owner polls the exact AXValue and continues as soon as the last
        // Unicode chunk is observable. A fixed post-typing sleep only delayed semantic
        // Send and widened the interval in which the user could change focus.
        logger.info("Issued targeted Unicode text events pid=\(pid, privacy: .public) utf16Units=\(utf16.count, privacy: .public)")
        return true
    }

    /// Execute the exact chunk loop behind targeted Unicode delivery through an
    /// injectable posting closure. Production supplies real CGEvents; tests supply a
    /// counter so they can prove a failed boundary causes zero later mutations. The
    /// boundary is evaluated immediately before every irreversible chunk.
    @MainActor
    static func runTargetedUnicodeChunks(
        _ utf16: [UInt16],
        chunkSize: Int = 20,
        beforeChunk: ((Int) -> Bool)? = nil,
        postChunk: ([UInt16]) async -> Bool
    ) async -> Bool {
        guard chunkSize > 0 else { return false }
        for start in stride(from: 0, to: utf16.count, by: chunkSize) {
            guard beforeChunk?(start) != false else { return false }
            let end = min(start + chunkSize, utf16.count)
            guard await postChunk(Array(utf16[start..<end])) else {
                return false
            }
        }
        return true
    }

    @MainActor
    private static func makeOtherEvent(
        typeRawValue: UInt,
        subtypeRawValue: UInt16
    ) -> CGEvent? {
        guard let eventType = NSEvent.EventType(rawValue: typeRawValue) else { return nil }
        return NSEvent.otherEvent(
            with: eventType,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: Int16(bitPattern: subtypeRawValue),
            data1: 0,
            data2: 0
        )?.cgEvent
    }

    // MARK: - Auto Send Keys

    // Feature B (robust double-Enter) tunables.
    //
    // Historical builds retried plain Return generically when the first event could be
    // dropped under load. That is not safe for terminals/editors: a handled first Return
    // can make the second act on a new prompt or surface. Current delivery therefore
    // leaves this legacy mechanism disabled. The sole permitted retry is orchestrated
    // separately by TranscriptionDelivery only after a readable unchanged OpenAI
    // composer proves the first semantic action did not submit.

    // Base gap before the redundant Enter (covers ordinary, non-lagging cases).
    private static let doubleEnterBaseDelay: TimeInterval = 0.12   // 120ms
    // Extra delay added per character of pasted transcript — longer paste means the
    // field settles slower, so the redundant Enter needs a touch more headroom.
    private static let doubleEnterPerCharDelay: TimeInterval = 0.0004 // 0.4ms/char
    // Hard ceiling so a very long transcript can't make the redundant Enter feel
    // sluggish. ~600ms total keeps it imperceptible-to-snappy in practice.
    private static let doubleEnterMaxDelay: TimeInterval = 0.60     // 600ms

    // `transcriptLength` scales the disabled-by-default legacy retry delay. Production
    // chat delivery uses one humanized HID event with an exact-focus preflight; it never
    // uses System Events, whose AppleScript execution can drift after a focus change.
    @MainActor
    static func performAutoSend(
        _ key: AutoSendKey,
        transcriptLength: Int = 0,
        expectedFrontmostPID: pid_t,
        method: AutoSendMethod = .cgEvent,
        sendRedundantEnter: Bool = false,
        preflight: (() -> Bool)? = nil
    ) async -> AutoSendResult {
        guard key.isEnabled else {
            logger.error("Refused to auto-send a disabled key")
            return .commandNotPosted
        }
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required to auto-send Return")
            return .commandNotPosted
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedFrontmostPID else {
            logger.error("Refused to auto-send Return because the saved destination is not frontmost expectedPid=\(expectedFrontmostPID, privacy: .public) actualPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
            return .commandNotPosted
        }
        guard preflight?() != false else {
            logger.error("Refused to auto-send Return because the exact-input preflight did not match")
            return .commandNotPosted
        }

        let firstResult = await issueAutoSendKey(
            key,
            method: method,
            preflight: preflight
        )
        guard firstResult.didPostAutoSendCommand else { return firstResult }

        // Feature B: schedule a SECOND Return ONLY for plain Enter, after a
        // length-scaled delay, to survive a lag-dropped first keystroke.
        guard sendRedundantEnter, key == .enter else { return .commandPosted }

        let scaledDelay = min(
            doubleEnterBaseDelay + Double(max(transcriptLength, 0)) * doubleEnterPerCharDelay,
            doubleEnterMaxDelay
        )

        await wait(scaledDelay)

        // The primary Return was posted successfully, so a failed safety retry is
        // logged but does not turn the whole delivery into a visible false failure.
        // Most importantly, never let the redundant Return land in another app.
        guard AXIsProcessTrusted() else {
            logger.error("Skipped redundant auto-send Return because Accessibility permission was revoked")
            return .commandPosted
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedFrontmostPID else {
            logger.notice("Skipped redundant auto-send Return because focus moved expectedPid=\(expectedFrontmostPID, privacy: .public) actualPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
            return .commandPosted
        }
        guard preflight?() != false else {
            logger.notice("Skipped redundant auto-send Return because the exact-input preflight changed")
            return .commandPosted
        }

        let retryResult = await issueAutoSendKey(
            .enter,
            method: method,
            preflight: preflight
        )
        if !retryResult.didPostAutoSendCommand {
            logger.error("Failed to issue redundant auto-send Return")
        }

        return .commandPosted
    }

    /// Issue one ordinary global HID key only while the caller proves that its exact
    /// saved input owns system keyboard focus. This deliberately has no frontmost-app
    /// requirement because ChatGPT's Option-Space composer can own keyboard focus while
    /// its process is nonfrontmost. It is never a process-targeted Return and never
    /// activates or focuses an app; the preflight is repeated at Return-down.
    @MainActor
    static func performExactKeyboardFocusAutoSend(
        _ key: AutoSendKey,
        preflight: @escaping () -> Bool
    ) async -> AutoSendResult {
        guard key.isEnabled,
              AXIsProcessTrusted(),
              preflight() else {
            logger.error("Refused exact-keyboard-focus auto-send because its saved input no longer owns system focus")
            return .commandNotPosted
        }
        return await issueAutoSendUsingCGEvent(
            key,
            preflight: preflight
        )
    }

    @MainActor
    private static func issueAutoSendKey(
        _ key: AutoSendKey,
        method: AutoSendMethod,
        preflight: (() -> Bool)?
    ) async -> AutoSendResult {
        switch method {
        case .systemEvents:
            return issueAutoSendUsingSystemEvents(key, preflight: preflight)
        case .cgEvent:
            return await issueAutoSendUsingCGEvent(key, preflight: preflight)
        }
    }

    @MainActor
    private static func issueAutoSendUsingSystemEvents(
        _ key: AutoSendKey,
        preflight: (() -> Bool)?
    ) -> AutoSendResult {
        let script: NSAppleScript?
        switch key {
        case .none:
            logger.error("Refused to auto-send .none")
            return .commandNotPosted
        case .enter:
            script = enterScript
        case .shiftEnter:
            script = shiftEnterScript
        case .commandEnter:
            script = commandEnterScript
        }

        guard let script else {
            logger.error("System Events auto-send script is unavailable")
            return .commandNotPosted
        }
        guard preflight?() != false else {
            logger.notice("Cancelled System Events auto-send because the exact-input preflight changed immediately before Return")
            return .commandNotPosted
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            logger.error("System Events auto-send failed key=\(key.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return .commandNotPosted
        }

        logger.info("Issued foreground auto-send through System Events key=\(key.rawValue, privacy: .public)")
        return .commandPosted
    }

    @MainActor
    private static func issueAutoSendUsingCGEvent(
        _ key: AutoSendKey,
        preflight: (() -> Bool)?
    ) async -> AutoSendResult {
        // HID system state plus a real down/up interval more closely resembles a
        // physical key press than the old back-to-back private-state events. The old
        // pair worked in Terminal but was ignored by the OpenAI Electron composer.
        let source = CGEventSource(stateID: .hidSystemState)
        guard let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true),
              let enterUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) else {
            logger.error("Failed to create auto-send Return keyboard events")
            return .commandNotPosted
        }

        switch key {
        case .none:
            logger.error("Refused to auto-send .none")
            return .commandNotPosted
        case .enter:
            enterDown.flags = []
            enterUp.flags = []
        case .shiftEnter:
            enterDown.flags = .maskShift
            enterUp.flags = .maskShift
        case .commandEnter:
            enterDown.flags = .maskCommand
            enterUp.flags = .maskCommand
        }

        guard preflight?() != false else {
            logger.notice("Cancelled humanized CGEvent auto-send because the exact-input preflight changed immediately before Return-down")
            return .commandNotPosted
        }
        enterDown.post(tap: .cghidEventTap)
        await wait(0.03)
        enterUp.post(tap: .cghidEventTap)
        logger.info("Issued humanized foreground CGEvent auto-send key=\(key.rawValue, privacy: .public)")
        return .commandPosted
    }
}

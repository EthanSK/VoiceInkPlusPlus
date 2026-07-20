import Foundation
import AppKit
import Carbon
import Darwin
import os

class CursorPaster {
    private typealias ClipboardItemSnapshot = [(NSPasteboard.PasteboardType, Data)]
    private typealias ClipboardSnapshot = [ClipboardItemSnapshot]
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CursorPaster")

    enum PasteResult: Equatable {
        case commandPosted
        case commandNotPosted
        case actionGuardRefused

        var didPostPasteCommand: Bool {
            self == .commandPosted
        }
    }

    enum AutoSendResult: Equatable {
        case commandPosted
        case commandNotPosted
        case actionGuardRefused

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
        canPost: @escaping @MainActor () -> Bool = { true }
    ) -> Task<PasteResult, Never> {
        Task { @MainActor in
            await performPasteSession(text, canPost: canPost)
        }
    }

    @MainActor
    static func pasteAtCursorAndWaitUntilPosted(_ text: String) async -> PasteResult {
        await startPasteAtCursor(text).value
    }

    @MainActor
    private static func performPasteSession(
        _ text: String,
        canPost: @escaping @MainActor () -> Bool
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

        await wait(prePasteDelay)

        // Clipboard preparation intentionally precedes the delay, but Cmd-V is
        // irreversible. Revalidate the saved exact input at this last boundary so a
        // newer click cannot receive the transcription or trigger a compensating focus
        // rewrite. A refused paste leaves the transcript safely on the clipboard.
        guard canPost() else {
            logger.error("Refused foreground paste because the exact-input action guard changed")
            return .actionGuardRefused
        }

        let pasteResult = await postPasteCommand(canPost: canPost)
        if shouldRestoreClipboard, pasteResult != .actionGuardRefused {
            scheduleClipboardRestore(
                savedContents,
                expectedText: text,
                sessionID: sessionID,
                on: pasteboard
            )
        }

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
        canPost: @escaping @MainActor () -> Bool
    ) async -> PasteResult {
        guard canPost() else { return .actionGuardRefused }
        if PasteMethod.current() == .appleScript {
            return pasteUsingAppleScript() ? .commandPosted : .commandNotPosted
        } else {
            return await pasteFromClipboard(canPost: canPost)
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
    private static func pasteUsingAppleScript() -> Bool {
        guard let script = layoutSwitchesToQWERTYOnCommand ? pasteScriptKeyCode : pasteScriptKeystroke else {
            logger.error("AppleScript paste script is unavailable")
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
        canPost: @escaping @MainActor () -> Bool
    ) async -> PasteResult {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required to paste with simulated key events")
            return .commandNotPosted
        }

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

        guard canPost() else { return .actionGuardRefused }
        cmdDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        // Cmd-down and V-down are separated only to match a real shortcut. Re-prove
        // the exact input after that suspension; on refusal, release Command without
        // ever posting V so a newer click cannot receive the transcript.
        guard canPost() else {
            cmdUp.post(tap: .cghidEventTap)
            return .actionGuardRefused
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
    /// Emit bounded Unicode only after FocusLockService has opened and verified one
    /// exact internal activation-state session. This function deliberately does not
    /// begin/end its own nested session; text and any later semantic Send action must
    /// remain bound to the same prepared editor until the caller finishes it.
    static func typeTextIntoPreparedTargetedProcess(
        _ text: String,
        pid: pid_t,
        canPost: @escaping @MainActor () -> Bool,
        canRevalidateContext: @escaping @MainActor () -> Bool
    ) async -> Bool {
        guard !text.isEmpty,
              AXIsProcessTrusted(),
              canPost(),
              canRevalidateContext() else {
            return false
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)
        for start in stride(from: 0, to: utf16.count, by: 20) {
            // PID-addressed Unicode follows Electron's current internal editor. Recheck
            // the exact window/editor plus target-not-system-focused boundary before
            // every chunk so a long transcript cannot split into a newer composer.
            guard canPost() else {
                logger.error("Stopped targeted Unicode because the exact session boundary changed pid=\(pid, privacy: .public) utf16Offset=\(start, privacy: .public)")
                return false
            }
            // The full task/document resolver is intentionally less frequent than the
            // fast per-chunk boundary: Chromium history trees can be large. Re-run it
            // every 200 UTF-16 units so context drift cannot persist through long text.
            if start > 0, start.isMultiple(of: 200),
               !canRevalidateContext() {
                logger.error("Stopped targeted Unicode because exact context revalidation failed pid=\(pid, privacy: .public) utf16Offset=\(start, privacy: .public)")
                return false
            }
            let end = min(start + 20, utf16.count)
            let chunk = Array(utf16[start..<end])
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
        }
        await wait(0.05)
        guard canPost(), canRevalidateContext() else { return false }
        logger.info("Issued targeted Unicode text events pid=\(pid, privacy: .public) utf16Units=\(utf16.count, privacy: .public)")
        return true
    }

    /// Click one exact, action-time-revalidated OpenAI Send control without moving
    /// the system cursor or bringing its app forward.
    ///
    /// This is intentionally smaller than Cua/Trope's general background driver.
    /// FocusLockService already owns and verifies the one internal activation-state
    /// session, so this primitive omits PSN focus-without-raise and every activation,
    /// public PID-post, and HID-tap fallback. All five NSEvent-bridged mouse events are
    /// stamped before the first post. The off-window primer has no semantic target;
    /// the target mouse-down is the sole irreversible Send attempt, and mouse-up is
    /// unconditional cleanup. The caller must verify exact composer clear/reset and
    /// must never follow this with AXPress, Return, or a second click.
    @MainActor
    static func performTargetedOpenAISendClick(
        targetPID: pid_t,
        windowID: CGWindowID,
        targetPoint: CGPoint,
        targetPointInWindow: CGPoint,
        offWindowPoint: CGPoint,
        canPost: @MainActor () -> Bool
    ) async -> AutoSendResult {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required for targeted OpenAI Send click")
            return .commandNotPosted
        }
        guard canPost() else {
            logger.error("Refused targeted OpenAI Send click because the exact-input boundary changed targetPid=\(targetPID, privacy: .public)")
            return .actionGuardRefused
        }

        func makeMouseEvent(
            _ type: NSEvent.EventType,
            clickCount: Int
        ) -> CGEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: Int(windowID),
                context: nil,
                eventNumber: 0,
                clickCount: clickCount,
                pressure: 1
            )?.cgEvent
        }

        guard let move = makeMouseEvent(.mouseMoved, clickCount: 0),
              let primerDown = makeMouseEvent(.leftMouseDown, clickCount: 1),
              let primerUp = makeMouseEvent(.leftMouseUp, clickCount: 1),
              let targetDown = makeMouseEvent(.leftMouseDown, clickCount: 1),
              let targetUp = makeMouseEvent(.leftMouseUp, clickCount: 1) else {
            logger.error("Failed to create NSEvent-bridged targeted OpenAI Send click events targetPid=\(targetPID, privacy: .public)")
            return .commandNotPosted
        }

        let clickGroupID = Int64(
            (ProcessInfo.processInfo.systemUptime * 1_000_000)
                .truncatingRemainder(dividingBy: Double(Int32.max))
        )
        let offWindowLocalPoint = CGPoint(x: -2_048, y: -2_048)
        let preparations = [
            SkyLightTargetedMouseEventPost.prepareMouseEvent(
                move,
                targetPID: targetPID,
                windowID: windowID,
                screenPoint: targetPoint,
                windowLocalPoint: targetPointInWindow,
                phase: 2,
                clickState: 0,
                clickGroupID: clickGroupID
            ),
            SkyLightTargetedMouseEventPost.prepareMouseEvent(
                primerDown,
                targetPID: targetPID,
                windowID: windowID,
                screenPoint: offWindowPoint,
                windowLocalPoint: offWindowLocalPoint,
                phase: 1,
                clickState: 1,
                clickGroupID: clickGroupID
            ),
            SkyLightTargetedMouseEventPost.prepareMouseEvent(
                primerUp,
                targetPID: targetPID,
                windowID: windowID,
                screenPoint: offWindowPoint,
                windowLocalPoint: offWindowLocalPoint,
                phase: 2,
                clickState: 1,
                clickGroupID: clickGroupID
            ),
            SkyLightTargetedMouseEventPost.prepareMouseEvent(
                targetDown,
                targetPID: targetPID,
                windowID: windowID,
                screenPoint: targetPoint,
                windowLocalPoint: targetPointInWindow,
                phase: 3,
                clickState: 1,
                clickGroupID: clickGroupID
            ),
            SkyLightTargetedMouseEventPost.prepareMouseEvent(
                targetUp,
                targetPID: targetPID,
                windowID: windowID,
                screenPoint: targetPoint,
                windowLocalPoint: targetPointInWindow,
                phase: 3,
                clickState: 1,
                clickGroupID: clickGroupID
            )
        ]
        guard preparations.allSatisfy({ $0 }), canPost() else {
            logger.error("Targeted OpenAI Send click preparation failed or exact-input boundary changed targetPid=\(targetPID, privacy: .public) bridgeAvailable=\(SkyLightTargetedMouseEventPost.isAvailable, privacy: .public) preparedCount=\(preparations.filter { $0 }.count, privacy: .public)")
            return canPost() ? .commandNotPosted : .actionGuardRefused
        }

        guard SkyLightTargetedMouseEventPost.postPreparedEvent(
            move,
            to: targetPID
        ) else {
            return .commandNotPosted
        }
        await wait(0.015)
        guard canPost(),
              SkyLightTargetedMouseEventPost.postPreparedEvent(
                primerDown,
                to: targetPID
              ) else {
            return canPost() ? .commandNotPosted : .actionGuardRefused
        }
        await wait(0.001)
        _ = SkyLightTargetedMouseEventPost.postPreparedEvent(
            primerUp,
            to: targetPID
        )
        await wait(0.1)

        // The primer is deliberately outside the exact window. Revalidate every
        // saved-input and Send-vs-Stop condition once more before the only target hit.
        guard canPost() else {
            logger.notice("Targeted OpenAI Send click cancelled after off-window primer because its action boundary changed targetPid=\(targetPID, privacy: .public)")
            return .actionGuardRefused
        }
        guard SkyLightTargetedMouseEventPost.postPreparedEvent(
            targetDown,
            to: targetPID
        ) else {
            return .commandNotPosted
        }
        await wait(0.001)
        let boundaryAfterMouseDown = canPost()
        let mouseUpPosted = SkyLightTargetedMouseEventPost.postPreparedEvent(
            targetUp,
            to: targetPID
        )
        if !mouseUpPosted {
            logger.fault("Targeted OpenAI Send mouse-up cleanup failed after posted mouse-down targetPid=\(targetPID, privacy: .public)")
        }
        logger.info("Issued one targeted OpenAI Send click targetPid=\(targetPID, privacy: .public) windowId=\(windowID, privacy: .public) targetX=\(Int(targetPoint.x), privacy: .public) targetY=\(Int(targetPoint.y), privacy: .public) mouseUpPosted=\(mouseUpPosted, privacy: .public) boundaryAfterMouseDown=\(boundaryAfterMouseDown, privacy: .public)")
        return .commandPosted
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

    /// Submit one already-verified Telegram composer without activating Telegram.
    /// Telegram ignores the ordinary two-event per-PID Return used by earlier
    /// VoiceInk++ builds. A disposable Saved Messages probe established that its
    /// native composer instead accepts the public CoreGraphics sequence used by
    /// Computer Use: HID-system event source, modifier-state boundary, Return
    /// down/up, then restoration of the live modifier state. This stays Telegram-
    /// only and one-shot; the caller must revalidate exact chat identity immediately
    /// before calling and must verify that the exact composer cleared afterward.
    @MainActor
    static func performTargetedTelegramHIDReturn(
        targetPID: pid_t,
        canPost: @MainActor () -> Bool
    ) -> AutoSendResult {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required for targeted Telegram Return")
            return .commandNotPosted
        }
        guard canPost() else {
            logger.error("Refused targeted Telegram Return because the exact chat boundary changed targetPid=\(targetPID, privacy: .public)")
            return .actionGuardRefused
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let modifiersBegan = CGEvent(source: source),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 0x24,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 0x24,
                  keyDown: false
              ),
              let modifiersEnded = CGEvent(source: source) else {
            logger.error("Failed to create targeted Telegram Return sequence targetPid=\(targetPID, privacy: .public)")
            return .commandNotPosted
        }

        modifiersBegan.type = .flagsChanged
        modifiersBegan.flags = []
        keyDown.flags = []
        keyUp.flags = []
        modifiersEnded.type = .flagsChanged
        modifiersEnded.flags = CGEventSource.flagsState(.combinedSessionState)

        modifiersBegan.timestamp = mach_absolute_time()
        modifiersBegan.postToPid(targetPID)
        guard canPost() else {
            // The initial flags event has no Send semantics, but Telegram still needs
            // its modifier state repaired if the exact-chat boundary changed before
            // the sole irreversible Return-down.
            modifiersEnded.timestamp = mach_absolute_time()
            modifiersEnded.postToPid(targetPID)
            logger.notice("Cancelled targeted Telegram Return after modifier setup because the exact chat boundary changed targetPid=\(targetPID, privacy: .public)")
            return .actionGuardRefused
        }

        keyDown.timestamp = mach_absolute_time()
        keyDown.postToPid(targetPID)
        // Once Return-down is posted, key-up and modifier restoration are mandatory
        // cleanup. Never turn a later boundary change into a second Send attempt.
        keyUp.timestamp = mach_absolute_time()
        keyUp.postToPid(targetPID)
        modifiersEnded.timestamp = mach_absolute_time()
        modifiersEnded.postToPid(targetPID)

        let boundaryAfterAction = canPost()
        logger.info("Issued one targeted Telegram HID Return sequence targetPid=\(targetPID, privacy: .public) boundaryAfterAction=\(boundaryAfterAction, privacy: .public)")
        return .commandPosted
    }

    // MARK: - Auto Send Keys

    // This primitive issues exactly one system-keyboard-focused key. That includes a
    // non-activating panel which owns real keyboard focus while another application is
    // still reported frontmost. Any retry belongs in the surface-specific verifier:
    // only a readable unchanged OpenAI composer may receive one exact-focus-guarded
    // HID Return retry. Generic editors and terminals never receive a second Return.
    @MainActor
    static func performAutoSend(
        _ key: AutoSendKey,
        targetPID: pid_t,
        method: AutoSendMethod = .cgEvent,
        canPost: @escaping @MainActor () -> Bool
    ) async -> AutoSendResult {
        guard key.isEnabled else {
            logger.error("Refused to auto-send a disabled key")
            return .commandNotPosted
        }
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required to auto-send Return")
            return .commandNotPosted
        }
        guard canPost() else {
            logger.error("Refused to auto-send Return because the exact input no longer owns system keyboard focus targetPid=\(targetPID, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
            return .actionGuardRefused
        }

        // Re-run the caller's exact-input/continuity boundary at Return-down. This is
        // still one immediate HID action; it adds no settling delay or target mutation.
        return await issueAutoSendKey(
            key,
            method: method,
            preflight: { canPost() }
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

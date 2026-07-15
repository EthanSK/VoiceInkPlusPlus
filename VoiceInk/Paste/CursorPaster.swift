import Foundation
import AppKit
import ApplicationServices
import Carbon
import os

class CursorPaster {
    typealias ClipboardItemSnapshot = [(NSPasteboard.PasteboardType, Data)]
    typealias ClipboardSnapshot = [ClipboardItemSnapshot]
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CursorPaster")

    enum PasteResult: Equatable {
        case commandPosted
        case commandNotPosted
        /// Ethan changed the clipboard after this paste session installed its
        /// marker. Preserve his newer contents; the delivery layer must not replace
        /// them with its ordinary transcript-as-recovery fallback.
        case clipboardOwnershipLost

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
    private static let targetedUnicodeChunkSize = 20
    private static let targetedUnicodeFullValidationCadence = 16

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
            await performPasteSession(text, preflight: preflight)
        }
    }

    @MainActor
    static func pasteAtCursorAndWaitUntilPosted(
        _ text: String,
        preflight: (() -> Bool)? = nil
    ) async -> PasteResult {
        await startPasteAtCursor(text, preflight: preflight).value
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
            sessionID: sessionID
        ) else {
            logger.error("Failed to prepare clipboard for paste")
            return .commandNotPosted
        }

        await wait(prePasteDelay)

        let clipboardIsStillOwned = {
            pasteboardStillOwnedByPasteSession(
                pasteboard,
                expectedText: text,
                sessionID: sessionID
            )
        }
        guard clipboardIsStillOwned() else {
            logger.notice("Cancelled foreground paste because Ethan changed the clipboard during the paste delay")
            return .clipboardOwnershipLost
        }
        guard preflight?() != false else {
            logger.error("Refused foreground paste because exact focus changed")
            return .commandNotPosted
        }

        let pastePreflight = {
            (preflight?() != false)
                && clipboardIsStillOwned()
        }

        let pasteResult = await postPasteCommand(preflight: pastePreflight)
        let ownedImmediatelyAfterCommand = clipboardIsStillOwned()
        var restoredOwnedClipboard = false
        if shouldRestoreClipboard {
            // Clipboard restoration is part of the delivery transaction, not a
            // detached afterthought. TranscriptionDelivery keeps its serialization
            // lease until this awaited ownership check finishes, so a second
            // transcript can never snapshot the first transcript as Ethan's
            // "original" clipboard. If Ethan changes the clipboard meanwhile, the
            // session marker no longer matches and his newer contents win.
            restoredOwnedClipboard = await restoreClipboardAfterPaste(
                savedContents,
                expectedText: text,
                sessionID: sessionID,
                on: pasteboard
            )
        }

        if pasteResult == .commandNotPosted,
           (!ownedImmediatelyAfterCommand
                || (shouldRestoreClipboard && !restoredOwnedClipboard)) {
            // The combined per-key preflight can fail because focus moved or because
            // Ethan copied something. Only the latter forbids the outer delivery
            // failure handler from installing the transcript as a recovery clipboard.
            return .clipboardOwnershipLost
        }
        return pasteResult
    }

    static func snapshotClipboard(from pasteboard: NSPasteboard) -> ClipboardSnapshot {
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
            return await pasteFromClipboard(preflight: preflight)
        }
    }

    @MainActor
    @discardableResult
    static func restoreClipboardAfterPaste(
        _ savedContents: ClipboardSnapshot,
        expectedText: String,
        sessionID: String,
        on pasteboard: NSPasteboard
    ) async -> Bool {
        let delay = max(
            UserDefaults.standard.double(forKey: "clipboardRestoreDelay"),
            minimumClipboardRestoreDelay
        )

        await wait(delay)
        guard pasteboardStillOwnedByPasteSession(
            pasteboard,
            expectedText: expectedText,
            sessionID: sessionID
        ) else {
            return false
        }
        pasteboard.clearContents()
        if !savedContents.isEmpty {
            pasteboard.writeObjects(pasteboardItems(from: savedContents))
        }
        return true
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
        guard preflight?() != false else {
            logger.error("Refused AppleScript paste because the exact-focus preflight failed")
            return false
        }
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
        preflight: (() -> Bool)?
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

        guard preflight?() != false else {
            logger.error("Refused CGEvent paste because the exact-focus preflight failed before Command down")
            return .commandNotPosted
        }
        cmdDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        guard preflight?() != false else {
            cmdUp.post(tap: .cghidEventTap)
            logger.error("Aborted CGEvent paste because focus changed before V down")
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
        prepareInputSession: Bool = true,
        preflight: (() -> Bool)? = nil,
        fastPreflight: (() -> Bool)? = nil
    ) async -> Bool {
        guard !text.isEmpty,
              AXIsProcessTrusted() else {
            return false
        }
        if prepareInputSession,
           !beginTargetedInputSession(pid: pid) {
            return false
        }
        defer {
            if prepareInputSession {
                endTargetedInputSession(pid: pid)
            }
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let utf16Count = text.utf16.count
        let chunks = targetedUnicodeChunks(for: text)
        var postedAnyText = false
        guard preflight?() != false else {
            logger.error("Refused targeted Unicode because the full exact-input preflight failed pid=\(pid, privacy: .public)")
            return false
        }

        for (chunkIndex, chunk) in chunks.enumerated() {
            let boundaryPreflight = fastPreflight ?? preflight
            guard boundaryPreflight?() != false else {
                logger.error("Stopped targeted Unicode because the fast internal editor boundary failed pid=\(pid, privacy: .public) postedAny=\(postedAnyText, privacy: .public) chunk=\(chunkIndex, privacy: .public)")
                return false
            }
            if chunkIndex > 0,
               chunkIndex % targetedUnicodeFullValidationCadence == 0,
               preflight?() == false {
                logger.error("Stopped targeted Unicode because the periodic full exact-input preflight failed pid=\(pid, privacy: .public) postedAny=\(postedAnyText, privacy: .public) chunk=\(chunkIndex, privacy: .public)")
                return false
            }
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
                // A partial mutation is not a successful delivery. The caller will
                // verify the exact saved input and surface the safe clipboard fallback;
                // returning true here could incorrectly advance to auto-send after
                // only a prefix of Ethan's transcript reached the destination.
                return false
            }

            chunk.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
            }
            keyDown.postToPid(pid)
            postedAnyText = true
            await wait(0.005)
            keyUp.postToPid(pid)
            await wait(0.005)
        }
        guard preflight?() != false else {
            logger.error("Targeted Unicode finished posting but the final full exact-input preflight failed pid=\(pid, privacy: .public)")
            return false
        }
        await wait(0.05)
        logger.info("Issued targeted Unicode text events pid=\(pid, privacy: .public) utf16Units=\(utf16Count, privacy: .public)")
        return true
    }

    /// `CGEvent.keyboardSetUnicodeString` accepts UTF-16 units, but splitting the raw
    /// buffer at an arbitrary offset can bisect a surrogate pair and corrupt emoji or
    /// any non-BMP scalar. Pack complete Unicode scalars into bounded chunks instead.
    /// A multi-scalar grapheme may cross events, but every scalar remains well-formed
    /// and the event stream preserves their original order.
    static func targetedUnicodeChunks(for text: String) -> [[UInt16]] {
        guard !text.isEmpty else { return [] }
        var result: [[UInt16]] = []
        var current: [UInt16] = []
        current.reserveCapacity(targetedUnicodeChunkSize)

        for scalar in text.unicodeScalars {
            let scalarUnits = Array(String(scalar).utf16)
            if !current.isEmpty,
               current.count + scalarUnits.count > targetedUnicodeChunkSize {
                result.append(current)
                current = []
                current.reserveCapacity(targetedUnicodeChunkSize)
            }
            current.append(contentsOf: scalarUnits)
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    static func targetedUnicodeFullValidationChunkIndices(
        utf16Count: Int
    ) -> [Int] {
        guard utf16Count > 0 else { return [] }
        let chunkCount = Int(
            ceil(
                Double(utf16Count)
                    / Double(targetedUnicodeChunkSize)
            )
        )
        return Array(
            stride(
                from: targetedUnicodeFullValidationCadence,
                to: chunkCount,
                by: targetedUnicodeFullValidationCadence
            )
        )
    }

    @MainActor
    static func performAutoSendToKeyboardFocusedProcess(
        _ key: AutoSendKey,
        expectedKeyboardFocusedPID: pid_t,
        expectedFocusedElement: AXUIElement
    ) async -> AutoSendResult {
        guard key.isEnabled,
              AXIsProcessTrusted() else {
            return .commandNotPosted
        }
        guard systemFocusMatches(
            pid: expectedKeyboardFocusedPID,
            element: expectedFocusedElement
        ) else {
            logger.error("Refused keyboard-focused auto-send because the exact saved input no longer owns system focus expectedPid=\(expectedKeyboardFocusedPID, privacy: .public) actualPid=\(systemFocusedElement()?.pid ?? -1, privacy: .public)")
            return .commandNotPosted
        }
        let result = await issueAutoSendKey(
            key,
            method: .cgEvent,
            preflight: {
                systemFocusMatches(
                    pid: expectedKeyboardFocusedPID,
                    element: expectedFocusedElement
                )
            }
        )
        guard result.didPostAutoSendCommand else { return result }
        guard systemFocusedElement()?.pid == expectedKeyboardFocusedPID else {
            logger.error("Keyboard focus moved during ordinary HID auto-send expectedPid=\(expectedKeyboardFocusedPID, privacy: .public) actualPid=\(systemFocusedProcessIdentifier() ?? -1, privacy: .public)")
            return .commandNotPosted
        }
        logger.info("Issued ordinary HID auto-send to the current keyboard-focused process key=\(key.rawValue, privacy: .public) pid=\(expectedKeyboardFocusedPID, privacy: .public)")
        return .commandPosted
    }

    private static func systemFocusedProcessIdentifier() -> pid_t? {
        systemFocusedElement()?.pid
    }

    private static func systemFocusedElement() -> (element: AXUIElement, pid: pid_t)? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }
        var pid: pid_t = 0
        let element = focusedValue as! AXUIElement
        guard AXUIElementGetPid(element, &pid) == .success else {
            return nil
        }
        return (element, pid)
    }

    private static func systemFocusMatches(
        pid: pid_t,
        element: AXUIElement
    ) -> Bool {
        guard let focused = systemFocusedElement() else { return false }
        return focused.pid == pid && CFEqual(focused.element, element)
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
    // Problem: on a lagging Mac, a SINGLE auto-Enter sometimes doesn't register, so
    // the message never submits (worse on longer transcripts — the field is busy
    // settling the just-pasted text when the Enter arrives, so the keystroke gets
    // dropped). Fix: for a plain Return auto-send, post Return once immediately, then
    // post a SECOND Return after a short delay.
    //
    // Why this is safe (no double-send): after the first Enter submits, the input
    // field is empty, so a second Return is a harmless no-op. But if the first Enter
    // was DROPPED under load, the second one still submits. Net = redundancy without
    // ever sending twice.
    //
    // We ONLY double-fire for plain `.enter`. Shift+Enter / Cmd+Enter are typically
    // "insert newline" / "send" chord variants where a stray second keystroke could
    // add an unwanted newline, so those stay single-fire.

    // Base gap before the redundant Enter (covers ordinary, non-lagging cases).
    private static let doubleEnterBaseDelay: TimeInterval = 0.12   // 120ms
    // Extra delay added per character of pasted transcript — longer paste means the
    // field settles slower, so the redundant Enter needs a touch more headroom.
    private static let doubleEnterPerCharDelay: TimeInterval = 0.0004 // 0.4ms/char
    // Hard ceiling so a very long transcript can't make the redundant Enter feel
    // sluggish. ~600ms total keeps it imperceptible-to-snappy in practice.
    private static let doubleEnterMaxDelay: TimeInterval = 0.60     // 600ms

    // `transcriptLength` scales the optional redundant Enter delay. The caller
    // chooses System Events for OpenAI's Electron composer because a real live trace
    // showed it ignoring zero-duration CGEvents while Terminal accepted them. Both
    // routes remain foreground-only so a Return can never drift into another app.
    @MainActor
    static func performAutoSend(
        _ key: AutoSendKey,
        transcriptLength: Int = 0,
        expectedFrontmostPID: pid_t,
        method: AutoSendMethod = .cgEvent,
        sendRedundantEnter: Bool = true,
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
            logger.error("Refused foreground auto-send because the exact saved input no longer owns keyboard focus")
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
            logger.notice("Skipped redundant auto-send Return because the exact saved input changed")
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

    @MainActor
    private static func issueAutoSendKey(
        _ key: AutoSendKey,
        method: AutoSendMethod,
        preflight: (() -> Bool)? = nil
    ) async -> AutoSendResult {
        switch method {
        case .systemEvents:
            guard preflight?() != false else {
                logger.error("Refused System Events auto-send because its exact-focus preflight failed")
                return .commandNotPosted
            }
            return issueAutoSendUsingSystemEvents(key)
        case .cgEvent:
            return await issueAutoSendUsingCGEvent(key, preflight: preflight)
        }
    }

    @MainActor
    private static func issueAutoSendUsingSystemEvents(_ key: AutoSendKey) -> AutoSendResult {
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
        preflight: (() -> Bool)? = nil
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

        // Recheck the exact AX element immediately before the global key-down. A PID
        // check is insufficient when Ethan clicks another composer in the same app.
        guard preflight?() != false else {
            logger.error("Refused humanized CGEvent auto-send because its exact-focus preflight failed")
            return .commandNotPosted
        }
        enterDown.post(tap: .cghidEventTap)
        await wait(0.03)
        enterUp.post(tap: .cghidEventTap)
        logger.info("Issued humanized foreground CGEvent auto-send key=\(key.rawValue, privacy: .public)")
        return .commandPosted
    }
}

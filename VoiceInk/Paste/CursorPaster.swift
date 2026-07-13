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
    static func startPasteAtCursor(_ text: String) -> Task<PasteResult, Never> {
        Task { @MainActor in
            await performPasteSession(text)
        }
    }

    @MainActor
    static func pasteAtCursorAndWaitUntilPosted(_ text: String) async -> PasteResult {
        await startPasteAtCursor(text).value
    }

    @MainActor
    private static func performPasteSession(_ text: String) async -> PasteResult {
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

        let pasteResult = await postPasteCommand()
        if shouldRestoreClipboard {
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
    private static func postPasteCommand() async -> PasteResult {
        if PasteMethod.current() == .appleScript {
            return pasteUsingAppleScript() ? .commandPosted : .commandNotPosted
        } else {
            return await pasteFromClipboard()
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
    private static func pasteFromClipboard() async -> PasteResult {
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

        cmdDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
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

    // `transcriptLength` is the character count of the text just pasted; it scales
    // the redundant-Enter delay (see constants above). Defaults to 0 for callers
    // that don't have it (then the second Enter fires after just the base delay).
    static func performAutoSend(_ key: AutoSendKey, transcriptLength: Int = 0, targetPID: pid_t? = nil) {
        guard key.isEnabled else { return }
        guard AXIsProcessTrusted() else { return }

        let source = CGEventSource(stateID: .privateState)
        let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        let enterUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)

        switch key {
        case .none: return
        case .enter: break
        case .shiftEnter:
            enterDown?.flags = .maskShift
            enterUp?.flags   = .maskShift
        case .commandEnter:
            enterDown?.flags = .maskCommand
            enterUp?.flags   = .maskCommand
        }

        // First Return — posted immediately (in-process CGEvent, key code 36/0x24).
        postAutoSendEvent(enterDown, targetPID: targetPID)
        postAutoSendEvent(enterUp, targetPID: targetPID)

        // Feature B: schedule a SECOND Return ONLY for plain Enter, after a
        // length-scaled delay, to survive a lag-dropped first keystroke.
        guard key == .enter else { return }

        let scaledDelay = min(
            doubleEnterBaseDelay + Double(max(transcriptLength, 0)) * doubleEnterPerCharDelay,
            doubleEnterMaxDelay
        )

        // Build a fresh pair of events for the redundant press (CGEvents are
        // single-use once posted). Same key code 36, no modifiers (plain Enter).
        DispatchQueue.main.asyncAfter(deadline: .now() + scaledDelay) {
            // Re-check Accessibility in case it was revoked between the two posts.
            guard AXIsProcessTrusted() else { return }
            let retrySource = CGEventSource(stateID: .privateState)
            let retryDown = CGEvent(keyboardEventSource: retrySource, virtualKey: 0x24, keyDown: true)
            let retryUp   = CGEvent(keyboardEventSource: retrySource, virtualKey: 0x24, keyDown: false)
            postAutoSendEvent(retryDown, targetPID: targetPID)
            postAutoSendEvent(retryUp, targetPID: targetPID)
        }
    }

    private static func postAutoSendEvent(_ event: CGEvent?, targetPID: pid_t?) {
        guard let event else { return }
        if let targetPID {
            event.postToPid(targetPID) // A global event follows whatever app is frontmost after the 500ms paste delay; PID delivery keeps Return bound to the app that received the transcript even after focus moves elsewhere.
        } else {
            event.post(tap: .cghidEventTap)
        }
    }
}

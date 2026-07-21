import AppKit
import CoreGraphics
import Foundation

// Privacy-bounded diagnostic for comparing a known-working Computer Use Return
// with VoiceInk++'s rejected per-PID Return variants. It records only numeric
// event metadata delivered to Telegram; it never reads or logs message text.

private let telegramBundleIdentifier = "ru.keepcoder.Telegram"

guard let telegram = NSRunningApplication.runningApplications(
    withBundleIdentifier: telegramBundleIdentifier
).first else {
    fputs("Telegram is not running.\n", stderr)
    exit(2)
}

let keyMask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
    | (CGEventMask(1) << CGEventType.keyUp.rawValue)
    | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)

let callback: CGEventTapCallBack = { _, type, event, _ in
    guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
        return Unmanaged.passUnretained(event)
    }

    let nonzeroFields = (0...160).compactMap { raw -> String? in
        guard let field = CGEventField(rawValue: UInt32(raw)) else {
            return nil
        }
        let value = event.getIntegerValueField(field)
        return value == 0 ? nil : "\(raw)=\(value)"
    }.joined(separator: ",")

    print(
        "type=\(type.rawValue) timestamp=\(event.timestamp) "
            + "flags=\(event.flags.rawValue) fields=[\(nonzeroFields)]"
    )
    fflush(stdout)
    return Unmanaged.passUnretained(event)
}

guard let tap = CGEvent.tapCreateForPid(
    pid: telegram.processIdentifier,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: keyMask,
    callback: callback,
    userInfo: nil
) else {
    fputs("Could not create a Telegram process event tap.\n", stderr)
    exit(3)
}

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
CGEvent.tapEnable(tap: tap, enable: true)

let duration = min(
    max(Double(CommandLine.arguments.dropFirst().first ?? "15") ?? 15, 1),
    30
)
print("READY telegramPid=\(telegram.processIdentifier) durationSeconds=\(duration)")
fflush(stdout)
CFRunLoopRunInMode(.defaultMode, duration, false)

import AppKit
import ApplicationServices
import Foundation

// Privacy-bounded transition trace for comparing a known-working Computer Use
// action with VoiceInk++ transports. It logs only focus booleans, element/window
// identity equality, foreground pid, and editable character counts.

private let telegramBundleIdentifier = "ru.keepcoder.Telegram"

private func copyAttribute(
    _ name: String,
    from element: AXUIElement
) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element,
        name as CFString,
        &value
    ) == .success else {
        return nil
    }
    return value
}

private func elementAttribute(
    _ name: String,
    from element: AXUIElement
) -> AXUIElement? {
    guard let value = copyAttribute(name, from: element),
          CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return nil
    }
    return unsafeBitCast(value, to: AXUIElement.self)
}

private func stringAttribute(
    _ name: String,
    from element: AXUIElement
) -> String? {
    copyAttribute(name, from: element) as? String
}

private func boolAttribute(
    _ name: String,
    from element: AXUIElement
) -> Bool? {
    copyAttribute(name, from: element) as? Bool
}

struct State: Equatable {
    let frontmostPID: pid_t
    let telegramActive: Bool
    let appWindowMatches: Bool
    let appElementMatches: Bool
    let windowFocused: Bool?
    let windowMain: Bool?
    let composerFocused: Bool?
    let composerCharacters: Int
    let systemFocusPID: pid_t
}

guard AXIsProcessTrusted(),
      let telegram = NSRunningApplication.runningApplications(
          withBundleIdentifier: telegramBundleIdentifier
      ).first else {
    fputs("Telegram or Accessibility is unavailable.\n", stderr)
    exit(2)
}
let application = AXUIElementCreateApplication(telegram.processIdentifier)
guard let savedWindow = elementAttribute(
    kAXFocusedWindowAttribute,
    from: application
),
      let savedComposer = elementAttribute(
          kAXFocusedUIElementAttribute,
          from: application
      ),
      stringAttribute(kAXRoleAttribute, from: savedComposer)
        == kAXTextAreaRole else {
    fputs("Telegram has no internally focused text composer.\n", stderr)
    exit(3)
}

func state() -> State {
    let currentWindow = elementAttribute(
        kAXFocusedWindowAttribute,
        from: application
    )
    let currentElement = elementAttribute(
        kAXFocusedUIElementAttribute,
        from: application
    )
    let systemWide = AXUIElementCreateSystemWide()
    let systemElement = elementAttribute(
        kAXFocusedUIElementAttribute,
        from: systemWide
    )
    var systemFocusPID: pid_t = -1
    if let systemElement {
        _ = AXUIElementGetPid(systemElement, &systemFocusPID)
    }
    return State(
        frontmostPID: NSWorkspace.shared.frontmostApplication?
            .processIdentifier ?? -1,
        telegramActive: telegram.isActive,
        appWindowMatches: currentWindow.map({
            CFEqual($0, savedWindow)
        }) == true,
        appElementMatches: currentElement.map({
            CFEqual($0, savedComposer)
        }) == true,
        windowFocused: boolAttribute(
            kAXFocusedAttribute,
            from: savedWindow
        ),
        windowMain: boolAttribute(kAXMainAttribute, from: savedWindow),
        composerFocused: boolAttribute(
            kAXFocusedAttribute,
            from: savedComposer
        ),
        composerCharacters: stringAttribute(
            kAXValueAttribute,
            from: savedComposer
        )?.count ?? -1,
        systemFocusPID: systemFocusPID
    )
}

func render(_ value: State, elapsedMilliseconds: Int) -> String {
    "elapsedMs=\(elapsedMilliseconds) frontmostPid=\(value.frontmostPID) "
        + "telegramActive=\(value.telegramActive) "
        + "appWindowMatches=\(value.appWindowMatches) "
        + "appElementMatches=\(value.appElementMatches) "
        + "windowFocused=\(String(describing: value.windowFocused)) "
        + "windowMain=\(String(describing: value.windowMain)) "
        + "composerFocused=\(String(describing: value.composerFocused)) "
        + "composerChars=\(value.composerCharacters) "
        + "systemFocusPid=\(value.systemFocusPID)"
}

let started = ProcessInfo.processInfo.systemUptime
var previous = state()
print(render(previous, elapsedMilliseconds: 0))
fflush(stdout)
let durationSeconds = min(
    max(Double(CommandLine.arguments.dropFirst().first ?? "6") ?? 6, 1),
    15
)
while ProcessInfo.processInfo.systemUptime - started < durationSeconds {
    let current = state()
    if current != previous {
        let elapsed = Int(
            (ProcessInfo.processInfo.systemUptime - started) * 1_000
        )
        print(render(current, elapsedMilliseconds: elapsed))
        fflush(stdout)
        previous = current
    }
    usleep(1_000)
}

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

// Marker-gated diagnostic for the public CoreGraphics portion of the known-
// working Computer Use Return sequence. It deliberately targets only the
// audited Telegram build and an exact disposable Saved Messages draft.

private let telegramBundleIdentifier = "ru.keepcoder.Telegram"
private let expectedVersion = "12.9"
private let expectedBuild = "282526"
private let disposableMarker = "VIPP Telegram public Computer Use sequence probe"

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

guard CommandLine.arguments.contains(
    "--confirm-disposable-saved-messages-marker"
) else {
    fputs("Refusing to send without the explicit disposable-marker flag.\n", stderr)
    exit(2)
}
guard AXIsProcessTrusted() else {
    fputs("Accessibility permission is unavailable.\n", stderr)
    exit(3)
}
guard let telegram = NSRunningApplication.runningApplications(
    withBundleIdentifier: telegramBundleIdentifier
).first,
      let bundleURL = telegram.bundleURL,
      let bundle = Bundle(url: bundleURL),
      bundle.object(
          forInfoDictionaryKey: "CFBundleShortVersionString"
      ) as? String == expectedVersion,
      bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        == expectedBuild else {
    fputs("The running Telegram tuple is not the audited 12.9/282526 build.\n", stderr)
    exit(4)
}
guard let frontmostBefore = NSWorkspace.shared.frontmostApplication,
      frontmostBefore.processIdentifier != telegram.processIdentifier else {
    fputs("Telegram must be backgrounded for this probe.\n", stderr)
    exit(5)
}

let application = AXUIElementCreateApplication(telegram.processIdentifier)
guard let composer = elementAttribute(
    kAXFocusedUIElementAttribute,
    from: application
),
      stringAttribute(kAXRoleAttribute, from: composer) == kAXTextAreaRole,
      stringAttribute(kAXValueAttribute, from: composer) == disposableMarker else {
    fputs("The internally focused Telegram composer failed the exact marker gate.\n", stderr)
    exit(6)
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
    fputs("Could not synthesize the public Return sequence.\n", stderr)
    exit(7)
}

modifiersBegan.type = .flagsChanged
modifiersBegan.flags = []
keyDown.flags = []
keyUp.flags = []
modifiersEnded.type = .flagsChanged
modifiersEnded.flags = CGEventSource.flagsState(.combinedSessionState)

for event in [modifiersBegan, keyDown, keyUp, modifiersEnded] {
    event.timestamp = mach_absolute_time()
    event.postToPid(telegram.processIdentifier)
}

usleep(350_000)
let valueAfter = stringAttribute(kAXValueAttribute, from: composer)
let frontmostAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
let cleared = valueAfter?.isEmpty == true
let foregroundPreserved = frontmostAfter == frontmostBefore.processIdentifier
print(
    "route=publicComputerUseSequence composerCleared=\(cleared) "
        + "foregroundPreserved=\(foregroundPreserved) "
        + "targetActiveAfter=\(telegram.isActive)"
)
exit(cleared && foregroundPreserved && !telegram.isActive ? 0 : 8)

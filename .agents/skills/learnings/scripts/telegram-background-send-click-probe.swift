import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Privacy-bounded proof for Telegram's invisible-to-AX paper-plane Send control.
// It can submit only one exact disposable marker in the audited Telegram build.
// Compile this file together with VoiceInk/Paste/SkyLightTargetedMouseEventPost.swift.

private let telegramBundleIdentifier = "ru.keepcoder.Telegram"
private let expectedVersion = "12.9"
private let expectedBuild = "282526"
private let disposableMarker = "VIPP Telegram AX activation probe draft"
private let allowedDisposableValues = [
    disposableMarker,
    disposableMarker + "\n",
    disposableMarker + "\r",
]
private let sendInsetFromWindowRight: CGFloat = 31.5

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

private func pointAttribute(
    _ name: String,
    from element: AXUIElement
) -> CGPoint? {
    guard let value = copyAttribute(name, from: element),
          CFGetTypeID(value) == AXValueGetTypeID() else {
        return nil
    }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    var point = CGPoint.zero
    return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
}

private func sizeAttribute(
    _ name: String,
    from element: AXUIElement
) -> CGSize? {
    guard let value = copyAttribute(name, from: element),
          CFGetTypeID(value) == AXValueGetTypeID() else {
        return nil
    }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    var size = CGSize.zero
    return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
}

private func frame(of element: AXUIElement) -> CGRect? {
    guard let origin = pointAttribute(kAXPositionAttribute, from: element),
          let size = sizeAttribute(kAXSizeAttribute, from: element),
          size.width > 0,
          size.height > 0 else {
        return nil
    }
    return CGRect(origin: origin, size: size)
}

private func makeOtherEvent(
    typeRawValue: UInt,
    subtypeRawValue: UInt16
) -> CGEvent? {
    guard let eventType = NSEvent.EventType(rawValue: typeRawValue) else {
        return nil
    }
    return NSEvent.otherEvent(
        with: eventType,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        subtype: Int16(bitPattern: subtypeRawValue),
        data1: 0,
        data2: 0
    )?.cgEvent
}

private func beginTargetedInputSession(pid: pid_t) -> Bool {
    guard let keyFocusReturned = makeOtherEvent(
        typeRawValue: 21,
        subtypeRawValue: 0x8000
    ),
    let applicationActivated = makeOtherEvent(
        typeRawValue: NSEvent.EventType.appKitDefined.rawValue,
        subtypeRawValue: 1
    ) else {
        return false
    }
    keyFocusReturned.postToPid(pid)
    applicationActivated.postToPid(pid)
    return true
}

private func endTargetedInputSession(pid: pid_t) {
    makeOtherEvent(
        typeRawValue: NSEvent.EventType.appKitDefined.rawValue,
        subtypeRawValue: 2
    )?.postToPid(pid)
}

private func makeMouseEvent(
    _ type: NSEvent.EventType,
    windowID: CGWindowID,
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

@main
private enum TelegramBackgroundSendClickProbe {
static func main() {
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
guard let app = NSRunningApplication.runningApplications(
    withBundleIdentifier: telegramBundleIdentifier
).first,
      let bundleURL = app.bundleURL,
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
      frontmostBefore.processIdentifier != app.processIdentifier else {
    fputs("Telegram must be backgrounded for this probe.\n", stderr)
    exit(5)
}

let application = AXUIElementCreateApplication(app.processIdentifier)
guard let composer = elementAttribute(
    kAXFocusedUIElementAttribute,
    from: application
) else {
    fputs("Telegram exposes no internally focused element.\n", stderr)
    exit(6)
}
guard stringAttribute(kAXRoleAttribute, from: composer) == kAXTextAreaRole,
      stringAttribute(kAXValueAttribute, from: composer).map({
          allowedDisposableValues.contains($0)
      }) == true,
      boolAttribute(kAXFocusedAttribute, from: composer) == true else {
    let role = stringAttribute(kAXRoleAttribute, from: composer) ?? "nil"
    let chars = stringAttribute(kAXValueAttribute, from: composer)?.count ?? -1
    let focused = boolAttribute(kAXFocusedAttribute, from: composer)
        .map(String.init(describing:)) ?? "nil"
    fputs(
        "The internally focused Telegram element failed the disposable marker "
            + "gate role=\(role) chars=\(chars) focused=\(focused).\n",
        stderr
    )
    exit(6)
}
guard let window = elementAttribute(
    kAXFocusedWindowAttribute,
    from: application
) else {
    fputs("Telegram exposes no internally focused window.\n", stderr)
    exit(6)
}
guard let composerFrame = frame(of: composer),
      let windowFrame = frame(of: window),
      windowFrame.contains(composerFrame) else {
    fputs("The exact Telegram composer is not inside its focused window.\n", stderr)
    exit(6)
}
guard let windowID = SkyLightTargetedMouseEventPost.windowID(for: window) else {
    fputs("The exact Telegram AX window has no usable CGWindowID.\n", stderr)
    exit(6)
}

// Telegram 12.9/282526 publishes no Send AX element. In the audited compact
// window, the paper plane is centered on the composer and 31.5 points inside the
// exact window's right edge. Keep the geometric gate narrow so a new layout fails.
let targetPoint = CGPoint(
    x: windowFrame.maxX - sendInsetFromWindowRight,
    y: composerFrame.midY
)
let horizontalGap = targetPoint.x - composerFrame.maxX
guard windowFrame.width >= 380,
      windowFrame.width <= 460,
      composerFrame.height >= 42,
      composerFrame.height <= 76,
      horizontalGap >= 48,
      horizontalGap <= 84,
      windowFrame.contains(targetPoint) else {
    fputs("The audited Telegram composer/Send geometry changed.\n", stderr)
    exit(7)
}
let targetPointInWindow = CGPoint(
    x: targetPoint.x - windowFrame.minX,
    y: targetPoint.y - windowFrame.minY
)
let offWindowPoint = CGPoint(
    x: windowFrame.minX - max(windowFrame.width, 2_048),
    y: windowFrame.minY - max(windowFrame.height, 2_048)
)
let offWindowLocalPoint = CGPoint(x: -2_048, y: -2_048)

func boundaryMatches() -> Bool {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier
            == frontmostBefore.processIdentifier,
          !app.isTerminated,
          app.processIdentifier
            != NSWorkspace.shared.frontmostApplication?.processIdentifier,
          let currentComposer = elementAttribute(
              kAXFocusedUIElementAttribute,
              from: application
          ),
          CFEqual(currentComposer, composer),
          let currentWindow = elementAttribute(
              kAXFocusedWindowAttribute,
              from: application
          ),
          CFEqual(currentWindow, window),
          stringAttribute(kAXValueAttribute, from: composer).map({
              allowedDisposableValues.contains($0)
          }) == true,
          boolAttribute(kAXFocusedAttribute, from: composer) == true,
          frame(of: composer) == composerFrame,
          frame(of: window) == windowFrame else {
        return false
    }
    return true
}

guard beginTargetedInputSession(pid: app.processIdentifier) else {
    fputs("Could not open the bounded Telegram activation-state session.\n", stderr)
    exit(8)
}
defer { endTargetedInputSession(pid: app.processIdentifier) }
usleep(50_000)
guard boundaryMatches() else {
    fputs("The exact Telegram boundary changed after session preparation.\n", stderr)
    exit(9)
}

guard let move = makeMouseEvent(
    .mouseMoved,
    windowID: windowID,
    clickCount: 0
),
      let primerDown = makeMouseEvent(
          .leftMouseDown,
          windowID: windowID,
          clickCount: 1
      ),
      let primerUp = makeMouseEvent(
          .leftMouseUp,
          windowID: windowID,
          clickCount: 1
      ),
      let targetDown = makeMouseEvent(
          .leftMouseDown,
          windowID: windowID,
          clickCount: 1
      ),
      let targetUp = makeMouseEvent(
          .leftMouseUp,
          windowID: windowID,
          clickCount: 1
      ) else {
    fputs("Could not create the targeted Telegram mouse gesture.\n", stderr)
    exit(10)
}

let clickGroupID = Int64(
    (ProcessInfo.processInfo.systemUptime * 1_000_000)
        .truncatingRemainder(dividingBy: Double(Int32.max))
)
let preparations = [
    SkyLightTargetedMouseEventPost.prepareMouseEvent(
        move,
        targetPID: app.processIdentifier,
        windowID: windowID,
        screenPoint: targetPoint,
        windowLocalPoint: targetPointInWindow,
        phase: 2,
        clickState: 0,
        clickGroupID: clickGroupID
    ),
    SkyLightTargetedMouseEventPost.prepareMouseEvent(
        primerDown,
        targetPID: app.processIdentifier,
        windowID: windowID,
        screenPoint: offWindowPoint,
        windowLocalPoint: offWindowLocalPoint,
        phase: 1,
        clickState: 1,
        clickGroupID: clickGroupID
    ),
    SkyLightTargetedMouseEventPost.prepareMouseEvent(
        primerUp,
        targetPID: app.processIdentifier,
        windowID: windowID,
        screenPoint: offWindowPoint,
        windowLocalPoint: offWindowLocalPoint,
        phase: 2,
        clickState: 1,
        clickGroupID: clickGroupID
    ),
    SkyLightTargetedMouseEventPost.prepareMouseEvent(
        targetDown,
        targetPID: app.processIdentifier,
        windowID: windowID,
        screenPoint: targetPoint,
        windowLocalPoint: targetPointInWindow,
        phase: 3,
        clickState: 1,
        clickGroupID: clickGroupID
    ),
    SkyLightTargetedMouseEventPost.prepareMouseEvent(
        targetUp,
        targetPID: app.processIdentifier,
        windowID: windowID,
        screenPoint: targetPoint,
        windowLocalPoint: targetPointInWindow,
        phase: 3,
        clickState: 1,
        clickGroupID: clickGroupID
    ),
]
guard preparations.allSatisfy({ $0 }), boundaryMatches() else {
    fputs("Targeted Telegram mouse preparation or its final boundary failed.\n", stderr)
    exit(11)
}

guard SkyLightTargetedMouseEventPost.postPreparedEvent(
    move,
    to: app.processIdentifier
) else {
    fputs("Targeted Telegram move could not be posted.\n", stderr)
    exit(12)
}
usleep(15_000)
guard boundaryMatches(),
      SkyLightTargetedMouseEventPost.postPreparedEvent(
          primerDown,
          to: app.processIdentifier
      ) else {
    fputs("Targeted Telegram primer-down was refused.\n", stderr)
    exit(13)
}
usleep(1_000)
_ = SkyLightTargetedMouseEventPost.postPreparedEvent(
    primerUp,
    to: app.processIdentifier
)
usleep(100_000)
guard boundaryMatches(),
      SkyLightTargetedMouseEventPost.postPreparedEvent(
          targetDown,
          to: app.processIdentifier
      ) else {
    fputs("Targeted Telegram Send mouse-down was refused.\n", stderr)
    exit(14)
}
usleep(1_000)
let mouseUpPosted = SkyLightTargetedMouseEventPost.postPreparedEvent(
    targetUp,
    to: app.processIdentifier
)
usleep(500_000)

let frontmostAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
let foregroundPreserved = frontmostAfter == frontmostBefore.processIdentifier
let retainedValueAfter = stringAttribute(kAXValueAttribute, from: composer)
let liveComposerAfter = elementAttribute(
    kAXFocusedUIElementAttribute,
    from: application
)
let liveValueAfter = liveComposerAfter.flatMap {
    stringAttribute(kAXValueAttribute, from: $0)
}
let composerCleared = retainedValueAfter?.isEmpty == true
    || liveValueAfter?.isEmpty == true
print(
    "route=targetedTelegramSendClick composerCleared=\(composerCleared) "
        + "foregroundPreserved=\(foregroundPreserved) "
        + "mouseUpPosted=\(mouseUpPosted) targetActiveAfter=\(app.isActive)"
)
exit(composerCleared && foregroundPreserved && mouseUpPosted ? 0 : 15)
}
}

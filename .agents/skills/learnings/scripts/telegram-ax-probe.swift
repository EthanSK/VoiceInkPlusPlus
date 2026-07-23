import AppKit
import ApplicationServices
import CryptoKit
import Foundation

// Privacy-bounded live probe for Telegram's unusual parentless composer.
// It prints structure, actions, geometry, booleans, and hashed string metadata.
// Editable values, selected text, and message contents are never printed.

private let telegramBundleIdentifier = "ru.keepcoder.Telegram"
private let stringAttributes: [String] = [
    kAXTitleAttribute,
    kAXDescriptionAttribute,
    kAXHelpAttribute,
    kAXPlaceholderValueAttribute,
    kAXIdentifierAttribute,
    "AXDOMIdentifier",
]
private let skippedValueAttributes: Set<String> = [
    kAXValueAttribute,
    kAXSelectedTextAttribute,
    kAXSelectedTextRangeAttribute,
    kAXVisibleCharacterRangeAttribute,
]
private let safeSemanticLabels = [
    "send", "send message", "submit", "write a message", "saved messages",
]

private func copyAttribute(_ name: String, from element: AXUIElement) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

private func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
    copyAttribute(name, from: element) as? String
}

private func boolAttribute(_ name: String, from element: AXUIElement) -> Bool? {
    copyAttribute(name, from: element) as? Bool
}

private func elementAttribute(_ name: String, from element: AXUIElement) -> AXUIElement? {
    guard let value = copyAttribute(name, from: element),
          CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return nil
    }
    return unsafeBitCast(value, to: AXUIElement.self)
}

private func elementArrayAttribute(_ name: String, from element: AXUIElement) -> [AXUIElement] {
    guard let values = copyAttribute(name, from: element) as? [AnyObject] else { return [] }
    return values.compactMap { value in
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}

private func pointAttribute(_ name: String, from element: AXUIElement) -> CGPoint? {
    guard let value = copyAttribute(name, from: element),
          CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    var point = CGPoint.zero
    return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
}

private func sizeAttribute(_ name: String, from element: AXUIElement) -> CGSize? {
    guard let value = copyAttribute(name, from: element),
          CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    var size = CGSize.zero
    return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
}

private func redactedString(_ value: String) -> String {
    let normalized = value
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    if safeSemanticLabels.contains(where: {
        normalized.localizedCaseInsensitiveContains($0)
    }) {
        return String(reflecting: String(normalized.prefix(120)))
    }
    let digest = SHA256.hash(data: Data(normalized.utf8))
        .prefix(8)
        .map { String(format: "%02x", $0) }
        .joined()
    return "<redacted chars=\(normalized.count) sha256=\(digest)>"
}

private func summary(_ element: AXUIElement) -> String {
    var pid: pid_t = 0
    _ = AXUIElementGetPid(element, &pid)
    let role = stringAttribute(kAXRoleAttribute, from: element) ?? "nil"
    let subrole = stringAttribute(kAXSubroleAttribute, from: element) ?? "nil"
    var parts = ["pid=\(pid)", "role=\(role)", "subrole=\(subrole)"]
    if role == kAXTextAreaRole || role == kAXTextFieldRole,
       let value = stringAttribute(kAXValueAttribute, from: element) {
        parts.append("AXValueMetadata=\(redactedString(value))")
    }
    for name in stringAttributes {
        if let value = stringAttribute(name, from: element), !value.isEmpty {
            parts.append("\(name)=\(redactedString(value))")
        }
    }
    for name in [kAXEnabledAttribute, kAXFocusedAttribute, kAXMainAttribute] {
        if let value = boolAttribute(name, from: element) {
            parts.append("\(name)=\(value)")
        }
    }
    if let point = pointAttribute(kAXPositionAttribute, from: element) {
        parts.append("position=(\(Int(point.x)),\(Int(point.y)))")
    }
    if let size = sizeAttribute(kAXSizeAttribute, from: element) {
        parts.append("size=(\(Int(size.width)),\(Int(size.height)))")
    }
    for name in [
        kAXParentAttribute,
        kAXWindowAttribute,
        kAXTopLevelUIElementAttribute,
        kAXDefaultButtonAttribute,
        kAXCancelButtonAttribute,
    ] {
        if let related = elementAttribute(name, from: element) {
            let relatedRole = stringAttribute(kAXRoleAttribute, from: related) ?? "nil"
            parts.append("\(name)=role:\(relatedRole),hash:\(CFHash(related))")
        }
    }
    var actions: CFArray?
    if AXUIElementCopyActionNames(element, &actions) == .success,
       let names = actions as? [String], !names.isEmpty {
        parts.append("actions=\(names.sorted())")
    }
    var attributes: CFArray?
    if AXUIElementCopyAttributeNames(element, &attributes) == .success,
       let names = attributes as? [String] {
        let safeNames = names.filter { !skippedValueAttributes.contains($0) }.sorted()
        parts.append("attributes=\(safeNames)")
    }
    return parts.joined(separator: " ")
}

private func makeOtherEvent(typeRawValue: UInt, subtypeRawValue: Int16) -> CGEvent? {
    NSEvent.otherEvent(
        with: NSEvent.EventType(rawValue: typeRawValue) ?? .appKitDefined,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        subtype: subtypeRawValue,
        data1: 0,
        data2: 0
    )?.cgEvent
}

private func beginActivationStateProbe(pid: pid_t) -> Bool {
    guard let keyFocusReturned = makeOtherEvent(typeRawValue: 21, subtypeRawValue: Int16(bitPattern: 0x8000)),
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

private func endActivationStateProbe(pid: pid_t) {
    makeOtherEvent(
        typeRawValue: NSEvent.EventType.appKitDefined.rawValue,
        subtypeRawValue: 2
    )?.postToPid(pid)
}

private func dumpTree(_ root: AXUIElement, label: String, maximumNodes: Int = 500) {
    print("ROOT \(label): \(summary(root))")
    var queue: [(AXUIElement, Int, String)] = [(root, 0, label)]
    var cursor = 0
    var seen = Set<CFHashCode>()
    while cursor < queue.count, cursor < maximumNodes {
        let (element, depth, path) = queue[cursor]
        cursor += 1
        guard seen.insert(CFHash(element)).inserted else { continue }
        print("NODE depth=\(depth) path=\(path) \(summary(element))")
        let children = elementArrayAttribute(kAXChildrenAttribute, from: element)
        let navigationChildren = elementArrayAttribute("AXChildrenInNavigationOrder", from: element)
        let merged = children + navigationChildren.filter { candidate in
            !children.contains(where: { CFEqual($0, candidate) })
        }
        for (index, child) in merged.enumerated() {
            queue.append((child, depth + 1, "\(path)/\(index)"))
        }
    }
    print("SUMMARY label=\(label) visited=\(min(cursor, maximumNodes)) queued=\(queue.count)")
}

guard AXIsProcessTrusted() else {
    fputs("Accessibility permission is not available to this probe.\n", stderr)
    exit(2)
}
guard let app = NSRunningApplication.runningApplications(
    withBundleIdentifier: telegramBundleIdentifier
).first else {
    fputs("Telegram is not running.\n", stderr)
    exit(3)
}

let application = AXUIElementCreateApplication(app.processIdentifier)
print("TELEGRAM pid=\(app.processIdentifier) active=\(app.isActive)")
let activationStateProbe = CommandLine.arguments.contains("--activation-session")
if activationStateProbe {
    guard beginActivationStateProbe(pid: app.processIdentifier) else {
        fputs("Could not open the bounded activation-state probe.\n", stderr)
        exit(4)
    }
    defer { endActivationStateProbe(pid: app.processIdentifier) }
    Thread.sleep(forTimeInterval: 0.075)
    print("ACTIVATION_STATE_PROBE opened=true")
}
if let focused = elementAttribute(kAXFocusedUIElementAttribute, from: application) {
    print("APP_FOCUSED \(summary(focused))")
}
if let focusedWindow = elementAttribute(kAXFocusedWindowAttribute, from: application) {
    print("APP_FOCUSED_WINDOW \(summary(focusedWindow))")
}

let systemWide = AXUIElementCreateSystemWide()
if let focused = elementAttribute(kAXFocusedUIElementAttribute, from: systemWide) {
    print("SYSTEM_FOCUSED \(summary(focused))")
}

let windows = elementArrayAttribute(kAXWindowsAttribute, from: application)
print("WINDOW_COUNT \(windows.count)")
for (index, window) in windows.enumerated() {
    dumpTree(window, label: "window[\(index)]")
}

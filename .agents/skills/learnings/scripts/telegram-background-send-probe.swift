// This diagnostic adapts the authenticated per-PID keyboard event transport
// published by tropeai/trope-cua under the MIT License. It is deliberately
// Telegram- and marker-specific so it cannot submit an arbitrary user draft.
//
// MIT License
// Copyright (c) 2026 Victor Vannara
// Copyright (c) 2025 Cua AI, Inc.

import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ObjectiveC

private let telegramBundleIdentifier = "ru.keepcoder.Telegram"
private let expectedVersion = "12.9"
private let expectedBuild = "282526"
private let disposableMarker = "VIPP Telegram AX activation probe draft"

private func copyAttribute(_ name: String, from element: AXUIElement) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

private func elementAttribute(_ name: String, from element: AXUIElement) -> AXUIElement? {
    guard let value = copyAttribute(name, from: element),
          CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return nil
    }
    return unsafeBitCast(value, to: AXUIElement.self)
}

private func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
    copyAttribute(name, from: element) as? String
}

private enum AuthenticatedSkyLightKeyboardPost {
    private typealias PostToPid = @convention(c) (pid_t, CGEvent) -> Void
    private typealias SetAuthenticationMessage = @convention(c) (CGEvent, AnyObject) -> Void
    private typealias AuthenticationFactory = @convention(c) (
        AnyObject,
        Selector,
        UnsafeMutableRawPointer,
        Int32,
        UInt32
    ) -> AnyObject?

    private struct Symbols {
        let postToPid: PostToPid
        let setAuthenticationMessage: SetAuthenticationMessage
        let factory: AuthenticationFactory
        let messageClass: AnyClass
        let selector: Selector
    }

    private static let symbols: Symbols? = {
        _ = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        )
        func resolve<T>(_ name: String, as _: T.Type) -> T? {
            guard let pointer = dlsym(
                UnsafeMutableRawPointer(bitPattern: -2),
                name
            ) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let postToPid = resolve("SLEventPostToPid", as: PostToPid.self),
              let setAuthenticationMessage = resolve(
                  "SLEventSetAuthenticationMessage",
                  as: SetAuthenticationMessage.self
              ),
              let factory = resolve("objc_msgSend", as: AuthenticationFactory.self),
              let messageClass = NSClassFromString("SLSEventAuthenticationMessage") else {
            return nil
        }
        return Symbols(
            postToPid: postToPid,
            setAuthenticationMessage: setAuthenticationMessage,
            factory: factory,
            messageClass: messageClass,
            selector: NSSelectorFromString("messageWithEventRecord:pid:version:")
        )
    }()

    static func post(_ event: CGEvent, to pid: pid_t) -> Bool {
        guard let symbols,
              let record = eventRecord(from: event),
              let message = symbols.factory(
                  symbols.messageClass as AnyObject,
                  symbols.selector,
                  record,
                  pid,
                  0
              ) else {
            return false
        }
        symbols.setAuthenticationMessage(event, message)
        symbols.postToPid(pid, event)
        return true
    }

    private static func eventRecord(from event: CGEvent) -> UnsafeMutableRawPointer? {
        let base = Unmanaged.passUnretained(event).toOpaque()
        for offset in [24, 32, 16] {
            let slot = base.advanced(by: offset)
                .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            if let record = slot.pointee { return record }
        }
        return nil
    }
}

private enum FocusWithoutRaiseProbe {
    private typealias PostEventRecord = @convention(c) (
        UnsafeRawPointer,
        UnsafePointer<UInt8>
    ) -> Int32
    private typealias GetFrontProcess = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias GetProcessForPID = @convention(c) (
        pid_t,
        UnsafeMutableRawPointer
    ) -> Int32
    private typealias GetWindowID = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private static func resolve<T>(_ name: String, as _: T.Type) -> T? {
        guard let pointer = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2),
            name
        ) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    static func windowID(for window: AXUIElement) -> CGWindowID? {
        _ = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        )
        guard let getWindowID = resolve(
            "_AXUIElementGetWindow",
            as: GetWindowID.self
        ) else { return nil }
        var windowID = CGWindowID(0)
        return getWindowID(window, &windowID) == .success && windowID != 0
            ? windowID
            : nil
    }

    static func activate(
        targetPID: pid_t,
        targetWindowID: CGWindowID
    ) -> Bool {
        _ = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        )
        guard let postEventRecord = resolve(
            "SLPSPostEventRecordTo",
            as: PostEventRecord.self
        ),
              let getFrontProcess = resolve(
                  "_SLPSGetFrontProcess",
                  as: GetFrontProcess.self
              ),
              let getProcessForPID = resolve(
                  "GetProcessForPID",
                  as: GetProcessForPID.self
              ) else {
            return false
        }
        var previousPSN = [UInt32](repeating: 0, count: 2)
        var targetPSN = [UInt32](repeating: 0, count: 2)
        guard previousPSN.withUnsafeMutableBytes({
            getFrontProcess($0.baseAddress!) == 0
        }),
              targetPSN.withUnsafeMutableBytes({
                  getProcessForPID(targetPID, $0.baseAddress!) == 0
              }) else {
            return false
        }

        var buffer = [UInt8](repeating: 0, count: 0xF8)
        buffer[0x04] = 0xF8
        buffer[0x08] = 0x0D
        let windowID = UInt32(targetWindowID)
        buffer[0x3C] = UInt8(windowID & 0xFF)
        buffer[0x3D] = UInt8((windowID >> 8) & 0xFF)
        buffer[0x3E] = UInt8((windowID >> 16) & 0xFF)
        buffer[0x3F] = UInt8((windowID >> 24) & 0xFF)

        buffer[0x8A] = 0x02
        let defocusedPrevious = previousPSN.withUnsafeBytes { psn in
            buffer.withUnsafeBufferPointer { bytes in
                postEventRecord(psn.baseAddress!, bytes.baseAddress!) == 0
            }
        }
        buffer[0x8A] = 0x01
        let focusedTarget = targetPSN.withUnsafeBytes { psn in
            buffer.withUnsafeBufferPointer { bytes in
                postEventRecord(psn.baseAddress!, bytes.baseAddress!) == 0
            }
        }
        return defocusedPrevious && focusedTarget
    }
}

private func boolAttribute(_ name: String, from element: AXUIElement) -> Bool? {
    copyAttribute(name, from: element) as? Bool
}

private func writeBool(_ name: String, value: Bool, to element: AXUIElement) {
    _ = AXUIElementSetAttributeValue(
        element,
        name as CFString,
        (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
    )
}

guard CommandLine.arguments.contains("--confirm-disposable-saved-messages-marker") else {
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
      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        == expectedVersion,
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
guard let composer = elementAttribute(kAXFocusedUIElementAttribute, from: application) else {
    fputs("Telegram exposes no internally focused element.\n", stderr)
    exit(6)
}
let composerRole = stringAttribute(kAXRoleAttribute, from: composer)
let composerValue = stringAttribute(kAXValueAttribute, from: composer)
guard composerRole == kAXTextAreaRole,
      composerValue == disposableMarker else {
    let digest = composerValue.map {
        SHA256.hash(data: Data($0.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    } ?? "nil"
    fputs(
        "The focused Telegram element failed the disposable marker gate "
            + "role=\(composerRole ?? "nil") chars=\(composerValue?.count ?? -1) "
            + "sha256=\(digest).\n",
        stderr
    )
    exit(6)
}

let useFocusWithoutRaise = CommandLine.arguments.contains("--focus-without-raise")
let focusedWindow = elementAttribute(kAXFocusedWindowAttribute, from: application)
let priorWindowFocused = focusedWindow.flatMap {
    boolAttribute(kAXFocusedAttribute, from: $0)
}
let priorWindowMain = focusedWindow.flatMap {
    boolAttribute(kAXMainAttribute, from: $0)
}
let priorComposerFocused = boolAttribute(kAXFocusedAttribute, from: composer)
var wroteSyntheticFocus = false
defer {
    if wroteSyntheticFocus {
        if let focusedWindow, let priorWindowFocused {
            writeBool(kAXFocusedAttribute, value: priorWindowFocused, to: focusedWindow)
        }
        if let focusedWindow, let priorWindowMain {
            writeBool(kAXMainAttribute, value: priorWindowMain, to: focusedWindow)
        }
        if let priorComposerFocused {
            writeBool(kAXFocusedAttribute, value: priorComposerFocused, to: composer)
        }
    }
}
if useFocusWithoutRaise {
    guard let focusedWindow,
          let windowID = FocusWithoutRaiseProbe.windowID(for: focusedWindow) else {
        fputs("The exact Telegram window ID is unavailable.\n", stderr)
        exit(10)
    }
    writeBool(kAXFocusedAttribute, value: true, to: focusedWindow)
    writeBool(kAXMainAttribute, value: true, to: focusedWindow)
    writeBool(kAXFocusedAttribute, value: true, to: composer)
    wroteSyntheticFocus = true
    guard FocusWithoutRaiseProbe.activate(
        targetPID: app.processIdentifier,
        targetWindowID: windowID
    ) else {
        fputs("Focus-without-raise could not prepare the Telegram window.\n", stderr)
        exit(11)
    }
    usleep(50_000)
    writeBool(kAXFocusedAttribute, value: true, to: composer)
}

guard let down = CGEvent(
    keyboardEventSource: nil,
    virtualKey: 0x24,
    keyDown: true
),
      let up = CGEvent(
          keyboardEventSource: nil,
          virtualKey: 0x24,
          keyDown: false
      ),
      AuthenticatedSkyLightKeyboardPost.post(down, to: app.processIdentifier) else {
    fputs("Authenticated SkyLight Return-down could not be posted.\n", stderr)
    exit(7)
}
usleep(5_000)
guard AuthenticatedSkyLightKeyboardPost.post(up, to: app.processIdentifier) else {
    fputs("Return-down was posted but Return-up could not be posted; no retry was attempted.\n", stderr)
    exit(8)
}
usleep(350_000)

let valueAfter = stringAttribute(kAXValueAttribute, from: composer)
let frontmostAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
let cleared = valueAfter?.isEmpty == true
let foregroundPreserved = frontmostAfter == frontmostBefore.processIdentifier
print(
    "route=\(useFocusWithoutRaise ? "focusWithoutRaiseAuthenticatedSkyLightReturn" : "authenticatedSkyLightReturn") composerCleared=\(cleared) "
        + "foregroundPreserved=\(foregroundPreserved) "
        + "targetActiveAfter=\(app.isActive)"
)
exit(cleared && foregroundPreserved ? 0 : 9)

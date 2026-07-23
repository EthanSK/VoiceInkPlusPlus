// This file adapts the narrowly scoped background-mouse event stamping used by
// tropeai/trope-cua (itself derived from trycua/cua). Both projects publish the
// relevant macOS code under the MIT License. The notice is retained because the
// private-SPI bridge and Chromium event fields are a substantial adaptation.
//
// MIT License
//
// Copyright (c) 2026 Victor Vannara
// Copyright (c) 2025 Cua AI, Inc.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Minimal private-SPI bridge for one PID/window-addressed mouse gesture.
///
/// VoiceInk++ deliberately does not import Cua/Trope's general driver, PSN
/// focus-without-raise recipe, public `CGEvent.postToPid` double-post, or HID-tap
/// fallback. Those mechanisms either change application-active state, can issue
/// the same click twice, or move Ethan's physical cursor. The caller must already
/// own one verified exact-input activation session and must prepare every event
/// before the first irreversible target mouse-down.
enum SkyLightTargetedMouseEventPost {
    private typealias PostToPIDFunction = @convention(c) (pid_t, CGEvent) -> Void
    private typealias SetIntegerFieldFunction = @convention(c) (
        CGEvent,
        UInt32,
        Int64
    ) -> Void
    private typealias SetWindowLocationFunction = @convention(c) (
        CGEvent,
        CGPoint
    ) -> Void
    private typealias AXUIElementGetWindowFunction = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private struct ResolvedSymbols {
        let postToPID: PostToPIDFunction
        let setIntegerField: SetIntegerFieldFunction
        let setWindowLocation: SetWindowLocationFunction
        let getAXWindowID: AXUIElementGetWindowFunction
    }

    private static let resolvedSymbols: ResolvedSymbols? = {
        _ = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        )

        func resolve<Function>(_ name: String, as _: Function.Type) -> Function? {
            guard let symbol = dlsym(
                UnsafeMutableRawPointer(bitPattern: -2),
                name
            ) else {
                return nil
            }
            return unsafeBitCast(symbol, to: Function.self)
        }

        guard let postToPID = resolve(
            "SLEventPostToPid",
            as: PostToPIDFunction.self
        ),
        let setIntegerField = resolve(
            "SLEventSetIntegerValueField",
            as: SetIntegerFieldFunction.self
        ),
        let setWindowLocation = resolve(
            "CGEventSetWindowLocation",
            as: SetWindowLocationFunction.self
        ),
        let getAXWindowID = resolve(
            "_AXUIElementGetWindow",
            as: AXUIElementGetWindowFunction.self
        ) else {
            return nil
        }

        return ResolvedSymbols(
            postToPID: postToPID,
            setIntegerField: setIntegerField,
            setWindowLocation: setWindowLocation,
            getAXWindowID: getAXWindowID
        )
    }()

    static var isAvailable: Bool {
        resolvedSymbols != nil
    }

    static func windowID(for window: AXUIElement) -> CGWindowID? {
        guard let symbols = resolvedSymbols else { return nil }
        var windowID = CGWindowID(0)
        guard symbols.getAXWindowID(window, &windowID) == .success,
              windowID != 0 else {
            return nil
        }
        return windowID
    }

    /// Stamp all public and private fields before any event is posted. The caller
    /// creates the event through `NSEvent.cgEvent`; raw-CGEvent mouse events were
    /// filtered by Chromium in the audited MIT implementation.
    static func prepareMouseEvent(
        _ event: CGEvent,
        targetPID: pid_t,
        windowID: CGWindowID,
        screenPoint: CGPoint,
        windowLocalPoint: CGPoint,
        phase: Int64,
        clickState: Int64,
        clickGroupID: Int64
    ) -> Bool {
        guard targetPID > 0,
              windowID != 0,
              screenPoint.x.isFinite,
              screenPoint.y.isFinite,
              windowLocalPoint.x.isFinite,
              windowLocalPoint.y.isFinite,
              let symbols = resolvedSymbols else {
            return false
        }

        event.location = screenPoint
        event.flags = []
        event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        event.setIntegerValueField(.mouseEventSubtype, value: 3)
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        symbols.setIntegerField(event, 0, phase)
        symbols.setIntegerField(event, 40, Int64(targetPID))
        symbols.setIntegerField(event, 51, Int64(windowID))
        symbols.setIntegerField(event, 58, clickGroupID)
        symbols.setIntegerField(event, 91, Int64(windowID))
        symbols.setIntegerField(event, 92, Int64(windowID))
        symbols.setWindowLocation(event, windowLocalPoint)
        return true
    }

    /// Post exactly once through SkyLight. There is intentionally no public
    /// `CGEvent.postToPid` or HID-tap fallback: either could duplicate the Send or
    /// move the real cursor. Application behavior still requires clear/reset proof.
    static func postPreparedEvent(_ event: CGEvent, to pid: pid_t) -> Bool {
        guard pid > 0, let symbols = resolvedSymbols else { return false }
        // The five events are prepared up front so the target mouse-down cannot
        // encounter a half-resolved bridge, but Chromium still expects each posted
        // event to carry its real dispatch-time uptime. Reusing the near-identical
        // creation timestamps across the 100 ms primer gap made gesture ordering less
        // faithful to the audited Cua/Trope recipe and could be handled flakily.
        event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        symbols.postToPID(pid, event)
        return true
    }
}

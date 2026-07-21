import Foundation
import CoreGraphics
import CryptoKit
import ScreenCaptureKit
import os

/// Replay-safe visual identity for Telegram's parentless message composer.
///
/// Telegram 12.9 exposes the exact `AXTextArea` and one enclosing window while the
/// chat header remains absent from that window's Accessibility descendants. Saving
/// only the wrapper, geometry, or Telegram's internal focus can therefore address the
/// wrong chat after a chat switch. This helper captures only a SHA-256 digest of the
/// audited header crop. It never retains or logs screenshots, OCR, chat titles, or
/// message text.
struct TelegramWindowVisualIdentity: Equatable, Sendable {
    struct ApplicationTuple: Equatable, Sendable {
        let applicationBundleName: String
        let bundleIdentifier: String
        let shortVersion: String
        let build: String
    }

    let applicationTuple: ApplicationTuple
    let processIdentifier: pid_t
    let windowID: CGWindowID
    let captureWidth: Int
    let captureHeight: Int
    let headerDigest: Data
    let stableChatIdentityDigest: Data
}

/// Starts capture at the exact input-decision boundary without delaying recorder UI
/// or microphone startup. Delivery awaits this one result and fails closed if two
/// consecutive capture-time header samples were not byte-identical.
final class TelegramWindowVisualIdentityCapture: @unchecked Sendable {
    private let task: Task<TelegramWindowVisualIdentity?, Never>

    init(
        applicationTuple: TelegramWindowVisualIdentity.ApplicationTuple,
        processIdentifier: pid_t,
        windowID: CGWindowID
    ) {
        task = Task.detached(priority: .userInitiated) {
            await TelegramWindowVisualIdentityService.captureStableIdentity(
                applicationTuple: applicationTuple,
                processIdentifier: processIdentifier,
                windowID: windowID
            )
        }
    }

    func value() async -> TelegramWindowVisualIdentity? {
        await task.value
    }
}

enum TelegramWindowVisualIdentityService {
    struct HeaderDigestSample: Equatable, Sendable {
        let width: Int
        let height: Int
        let digest: Data
        let stableChatIdentityDigest: Data
    }

    // The normalized crop was audited against Telegram 12.9/282526. It contains the
    // selected chat header while excluding the message history and bottom composer.
    // A Telegram update must fail closed until this layout contract is re-audited.
    static let headerCrop = CGRect(x: 0.12, y: 0.035, width: 0.64, height: 0.065)
    // The complete header also contains Telegram's lower status/activity row. That
    // row can animate or change while the selected chat is still identical, which
    // made v2.0.245 reject the same saved composer. Keep replay safety exact rather
    // than fuzzy: hash only the audited avatar + primary chat-title row and require
    // that byte-for-byte digest at every mutation/action boundary.
    static let stableChatIdentityRegion = CGRect(
        x: 0.54,
        y: 0.14,
        width: 0.44,
        height: 0.52
    )
    private static let auditedTuple = TelegramWindowVisualIdentity.ApplicationTuple(
        applicationBundleName: "Telegram.app",
        bundleIdentifier: "ru.keepcoder.Telegram",
        shortVersion: "12.9",
        build: "282526"
    )
    private static let captureTimeoutSeconds: TimeInterval = 1.25
    private static let stabilityIntervalNanoseconds: UInt64 = 45_000_000
    private static let logger = Logger(
        subsystem: "com.ethansk.VoiceInkPlusPlus",
        category: "FocusLock"
    )

    static func isAudited(
        _ tuple: TelegramWindowVisualIdentity.ApplicationTuple
    ) -> Bool {
        tuple == auditedTuple
    }

    static func pixelCropRect(
        imageWidth: Int,
        imageHeight: Int,
        normalizedCrop: CGRect = headerCrop
    ) -> CGRect? {
        guard imageWidth > 0,
              imageHeight > 0,
              normalizedCrop.minX >= 0,
              normalizedCrop.minY >= 0,
              normalizedCrop.maxX <= 1,
              normalizedCrop.maxY <= 1,
              normalizedCrop.width > 0,
              normalizedCrop.height > 0 else {
            return nil
        }
        let x = Int(floor(CGFloat(imageWidth) * normalizedCrop.minX))
        let y = Int(floor(CGFloat(imageHeight) * normalizedCrop.minY))
        let maxX = Int(ceil(CGFloat(imageWidth) * normalizedCrop.maxX))
        let maxY = Int(ceil(CGFloat(imageHeight) * normalizedCrop.maxY))
        let width = maxX - x
        let height = maxY - y
        guard width > 0, height > 0, maxX <= imageWidth, maxY <= imageHeight else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func pixelStableChatIdentityRect(
        imageWidth: Int,
        imageHeight: Int,
        normalizedRegion: CGRect = stableChatIdentityRegion
    ) -> CGRect? {
        guard imageWidth > 0,
              imageHeight > 0,
              normalizedRegion.minX >= 0,
              normalizedRegion.minY >= 0,
              normalizedRegion.maxX <= 1,
              normalizedRegion.maxY <= 1,
              normalizedRegion.width > 0,
              normalizedRegion.height > 0 else {
            return nil
        }
        // Vision-style normalized coordinates are bottom-left based, while the
        // CGImage crop rows are top-left based for this captured buffer.
        let x = Int(floor(CGFloat(imageWidth) * normalizedRegion.minX))
        let y = Int(floor(CGFloat(imageHeight) * (1 - normalizedRegion.maxY)))
        let maxX = Int(ceil(CGFloat(imageWidth) * normalizedRegion.maxX))
        let maxY = Int(ceil(CGFloat(imageHeight) * (1 - normalizedRegion.minY)))
        guard maxX > x,
              maxY > y,
              maxX <= imageWidth,
              maxY <= imageHeight else {
            return nil
        }
        return CGRect(x: x, y: y, width: maxX - x, height: maxY - y)
    }

    static func stableIdentity(
        applicationTuple: TelegramWindowVisualIdentity.ApplicationTuple,
        processIdentifier: pid_t,
        windowID: CGWindowID,
        first: HeaderDigestSample?,
        second: HeaderDigestSample?
    ) -> TelegramWindowVisualIdentity? {
        guard isAudited(applicationTuple),
              windowID != 0,
              processIdentifier > 0,
              let first,
              let second,
              first.width == second.width,
              first.height == second.height,
              first.stableChatIdentityDigest == second.stableChatIdentityDigest,
              !first.stableChatIdentityDigest.isEmpty else {
            return nil
        }
        return TelegramWindowVisualIdentity(
            applicationTuple: applicationTuple,
            processIdentifier: processIdentifier,
            windowID: windowID,
            captureWidth: first.width,
            captureHeight: first.height,
            headerDigest: first.digest,
            stableChatIdentityDigest: first.stableChatIdentityDigest
        )
    }

    static func captureStableIdentity(
        applicationTuple: TelegramWindowVisualIdentity.ApplicationTuple,
        processIdentifier: pid_t,
        windowID: CGWindowID
    ) async -> TelegramWindowVisualIdentity? {
        guard isAudited(applicationTuple) else {
            logger.notice("Telegram visual identity capture refused unaudited app tuple")
            return nil
        }
        guard CGPreflightScreenCaptureAccess() else {
            logger.notice("Telegram visual identity capture unavailable because Screen Recording permission is missing")
            return nil
        }
        guard let first = await withTimeout(seconds: captureTimeoutSeconds, operation: {
            await captureHeaderDigest(
                processIdentifier: processIdentifier,
                windowID: windowID
            )
        }) else {
            logger.notice("Telegram visual identity capture could not read a non-blank first header sample")
            return nil
        }
        try? await Task.sleep(nanoseconds: stabilityIntervalNanoseconds)
        guard !Task.isCancelled,
              let second = await withTimeout(seconds: captureTimeoutSeconds, operation: {
                  await captureHeaderDigest(
                      processIdentifier: processIdentifier,
                      windowID: windowID
                  )
              }) else {
            logger.notice("Telegram visual identity capture could not read a non-blank second header sample")
            return nil
        }
        let identity = stableIdentity(
            applicationTuple: applicationTuple,
            processIdentifier: processIdentifier,
            windowID: windowID,
            first: first,
            second: second
        )
        if identity == nil {
            logger.notice("Telegram visual identity capture rejected unstable header samples")
        }
        return identity
    }

    static func matchesCurrentWindow(
        _ identity: TelegramWindowVisualIdentity
    ) async -> Bool {
        guard isAudited(identity.applicationTuple) else {
            logger.notice("Telegram visual identity revalidation refused unaudited app tuple")
            return false
        }
        guard CGPreflightScreenCaptureAccess() else {
            logger.notice("Telegram visual identity revalidation unavailable because Screen Recording permission is missing")
            return false
        }
        guard let current = await withTimeout(seconds: captureTimeoutSeconds, operation: {
            await captureHeaderDigest(
                processIdentifier: identity.processIdentifier,
                windowID: identity.windowID
            )
        }) else {
            logger.notice("Telegram visual identity revalidation could not read a non-blank header sample")
            return false
        }
        let dimensionsMatch = current.width == identity.captureWidth
            && current.height == identity.captureHeight
        let stableIdentityMatches = current.stableChatIdentityDigest
            == identity.stableChatIdentityDigest
        let matches = dimensionsMatch && stableIdentityMatches
        if !matches {
            logger.notice("Telegram visual identity revalidation rejected changed stable chat identity or dimensions dimensionsMatch=\(dimensionsMatch, privacy: .public) stableIdentityMatch=\(stableIdentityMatches, privacy: .public)")
        } else if current.digest != identity.headerDigest {
            logger.info("Telegram visual identity accepted dynamic-only header drift with exact avatar/title identity")
        }
        return matches
    }

    private static func captureHeaderDigest(
        processIdentifier: pid_t,
        windowID: CGWindowID
    ) async -> HeaderDigestSample? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard let window = content.windows.first(where: {
                $0.windowID == windowID
                    && $0.owningApplication?.processID == processIdentifier
                    && $0.windowLayer == 0
                    && $0.frame.width > 0
                    && $0.frame.height > 0
            }) else {
                return nil
            }

            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(window.frame.width.rounded()))
            configuration.height = max(1, Int(window.frame.height.rounded()))
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: configuration
            )
            guard let cropRect = pixelCropRect(
                imageWidth: image.width,
                imageHeight: image.height
            ),
            let cropped = image.cropping(to: cropRect),
            let canonical = canonicalRGBABytes(from: cropped),
            let stableIdentityRect = pixelStableChatIdentityRect(
                imageWidth: cropped.width,
                imageHeight: cropped.height
            ),
            let stableIdentityImage = cropped.cropping(to: stableIdentityRect),
            let stableIdentityBytes = canonicalRGBABytes(
                from: stableIdentityImage
            ) else {
                return nil
            }
            return HeaderDigestSample(
                width: image.width,
                height: image.height,
                digest: Data(SHA256.hash(data: canonical)),
                stableChatIdentityDigest: Data(
                    SHA256.hash(data: stableIdentityBytes)
                )
            )
        } catch {
            return nil
        }
    }

    /// Canonical RGBA avoids hashing provider padding or pixel-format metadata. The
    /// small non-uniformity gate rejects stable blank/protected captures without
    /// learning or persisting any readable Telegram content.
    private static func canonicalRGBABytes(from image: CGImage) -> Data? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var bytes = Data(count: bytesPerRow * height)
        let drewImage = bytes.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                          | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drewImage else { return nil }

        var distinctPixels = Set<UInt32>()
        bytes.withUnsafeBytes { rawBuffer in
            let pixels = rawBuffer.bindMemory(to: UInt32.self)
            let stride = max(1, pixels.count / 512)
            var index = 0
            while index < pixels.count, distinctPixels.count < 8 {
                distinctPixels.insert(pixels[index])
                index += stride
            }
        }
        return distinctPixels.count >= 4 ? bytes : nil
    }

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

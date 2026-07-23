import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ScreenCaptureKit
import Vision

/// Privacy-safe diagnostic for Telegram's visual exact-chat gate.
///
/// The probe never writes an image and never prints OCR text. It emits only window
/// dimensions, sample stability, cryptographic digests, and OCR observation counts.
/// That is enough to distinguish layout/dimension drift from an unstable header
/// without copying a chat name or message into logs.
@main
enum TelegramVisualIdentityProbe {
    private static let telegramBundleIdentifier = "ru.keepcoder.Telegram"
    private static let headerCrop = CGRect(
        x: 0.12,
        y: 0.035,
        width: 0.64,
        height: 0.065
    )
    // Audited within the header crop: avatar plus primary chat-title row. The
    // lower status row and left chat-list fragments are intentionally excluded.
    private static let stableChatIdentityRegion = CGRect(
        x: 0.54,
        y: 0.14,
        width: 0.44,
        height: 0.52
    )
    private static var sampleCount: Int {
        Int(ProcessInfo.processInfo.environment["VIPP_TELEGRAM_VISUAL_SAMPLES"] ?? "")
            .map { min(max($0, 2), 120) } ?? 8
    }
    private static var sampleIntervalNanoseconds: UInt64 {
        let milliseconds = Int(
            ProcessInfo.processInfo.environment["VIPP_TELEGRAM_VISUAL_INTERVAL_MS"] ?? ""
        ).map { min(max($0, 40), 5_000) } ?? 150
        return UInt64(milliseconds) * 1_000_000
    }
    private static let textFingerprintKey = SymmetricKey(size: .bits256)

    struct RecognizedLine {
        let digest: String
        let characterCount: Int
        let boundingBox: CGRect
    }

    struct Sample {
        let width: Int
        let height: Int
        let pixelDigest: String
        let stableRegionDigest: String
        let recognizedTextDigest: String?
        let recognizedLines: [RecognizedLine]
    }

    static func main() async {
        _ = NSApplication.shared
        guard CGPreflightScreenCaptureAccess() else {
            fputs("error=screen-recording-permission-missing\n", stderr)
            exit(2)
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            let candidates = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == telegramBundleIdentifier
                    && $0.windowLayer == 0
                    && $0.frame.width > 0
                    && $0.frame.height > 0
            }
            guard let window = candidates.max(by: {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            }) else {
                fputs("error=no-telegram-window candidateCount=0\n", stderr)
                exit(3)
            }

            print(
                "windowCount=\(candidates.count) selectedWindowId=\(window.windowID)"
                    + " ownerPid=\(window.owningApplication?.processID ?? -1)"
            )
            var samples: [Sample] = []
            for index in 0..<sampleCount {
                if index > 0 {
                    try? await Task.sleep(nanoseconds: sampleIntervalNanoseconds)
                }
                guard let sample = try await capture(window: window) else {
                    print("sample=\(index + 1) unavailable=true")
                    continue
                }
                samples.append(sample)
                print(
                    "sample=\(index + 1) width=\(sample.width) height=\(sample.height)"
                        + " pixelDigest=\(sample.pixelDigest)"
                        + " stableRegionDigest=\(sample.stableRegionDigest)"
                        + " recognizedLines=\(sample.recognizedLines.count)"
                        + " recognizedTextDigest=\(sample.recognizedTextDigest ?? "none")"
                )
                let lineMetadata = sample.recognizedLines.map {
                    let box = $0.boundingBox
                    return "\($0.digest.prefix(12))[\($0.characterCount)]@"
                        + "\(rounded(box.minX)),\(rounded(box.minY)),"
                        + "\(rounded(box.width)),\(rounded(box.height))"
                }.joined(separator: ";")
                print("sample=\(index + 1) lineMetadata=\(lineMetadata)")
            }

            guard let first = samples.first else {
                fputs("error=no-readable-samples\n", stderr)
                exit(4)
            }
            let dimensionsStable = samples.allSatisfy {
                $0.width == first.width && $0.height == first.height
            }
            let pixelsStable = samples.allSatisfy {
                $0.pixelDigest == first.pixelDigest
            }
            let stableRegionStable = samples.allSatisfy {
                $0.stableRegionDigest == first.stableRegionDigest
            }
            let recognizedTextStable = first.recognizedTextDigest != nil
                && samples.allSatisfy {
                    $0.recognizedTextDigest == first.recognizedTextDigest
                }
            let commonRecognizedLines = samples.dropFirst().reduce(
                into: Set(first.recognizedLines.map(\.digest))
            ) { common, sample in
                common.formIntersection(sample.recognizedLines.map(\.digest))
            }
            print(
                "summary readableSamples=\(samples.count)"
                    + " dimensionsStable=\(dimensionsStable)"
                    + " pixelsStable=\(pixelsStable)"
                    + " stableRegionStable=\(stableRegionStable)"
                    + " recognizedTextStable=\(recognizedTextStable)"
                    + " commonRecognizedLines=\(commonRecognizedLines.count)"
            )
        } catch {
            fputs("error=screen-capture-failed type=\(type(of: error))\n", stderr)
            exit(5)
        }
    }

    private static func capture(window: SCWindow) async throws -> Sample? {
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
        let rgba = canonicalRGBABytes(from: cropped) else {
            return nil
        }

        let recognized = try recognizedTextFingerprint(from: cropped)
        guard let stableRegion = crop(
            cropped,
            visionNormalizedRect: stableChatIdentityRegion
        ),
        let stableRegionRGBA = canonicalRGBABytes(from: stableRegion) else {
            return nil
        }
        return Sample(
            width: image.width,
            height: image.height,
            pixelDigest: sha256Hex(rgba),
            stableRegionDigest: sha256Hex(stableRegionRGBA),
            recognizedTextDigest: recognized.digest,
            recognizedLines: recognized.lines
        )
    }

    private static func pixelCropRect(
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect? {
        guard imageWidth > 0, imageHeight > 0 else { return nil }
        let x = Int(floor(CGFloat(imageWidth) * headerCrop.minX))
        let y = Int(floor(CGFloat(imageHeight) * headerCrop.minY))
        let maxX = Int(ceil(CGFloat(imageWidth) * headerCrop.maxX))
        let maxY = Int(ceil(CGFloat(imageHeight) * headerCrop.maxY))
        guard maxX > x, maxY > y,
              maxX <= imageWidth, maxY <= imageHeight else {
            return nil
        }
        return CGRect(x: x, y: y, width: maxX - x, height: maxY - y)
    }

    private static func recognizedTextFingerprint(
        from image: CGImage
    ) throws -> (digest: String?, lines: [RecognizedLine]) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observations = (request.results ?? []).sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 {
                return $0.boundingBox.midY > $1.boundingBox.midY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        let recognizedLines = observations.compactMap { observation -> (String, CGRect)? in
            guard let text = observation.topCandidates(1).first?.string else {
                return nil
            }
            let normalized = text.lowercased()
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            return normalized.isEmpty ? nil : (normalized, observation.boundingBox)
        }
        guard !recognizedLines.isEmpty else {
            return (nil, [])
        }
        return (
            hmacHex(Data(recognizedLines.map(\.0).joined(separator: "\n").utf8)),
            recognizedLines.map {
                RecognizedLine(
                    digest: hmacHex(Data($0.0.utf8)),
                    characterCount: $0.0.count,
                    boundingBox: $0.1
                )
            }
        )
    }

    private static func canonicalRGBABytes(from image: CGImage) -> Data? {
        let width = image.width
        let height = image.height
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
        return drewImage ? bytes : nil
    }

    private static func crop(
        _ image: CGImage,
        visionNormalizedRect rect: CGRect
    ) -> CGImage? {
        let x = Int(floor(CGFloat(image.width) * rect.minX))
        let y = Int(floor(CGFloat(image.height) * (1 - rect.maxY)))
        let maxX = Int(ceil(CGFloat(image.width) * rect.maxX))
        let maxY = Int(ceil(CGFloat(image.height) * (1 - rect.minY)))
        guard x >= 0, y >= 0, maxX <= image.width, maxY <= image.height,
              maxX > x, maxY > y else {
            return nil
        }
        return image.cropping(to: CGRect(
            x: x,
            y: y,
            width: maxX - x,
            height: maxY - y
        ))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmacHex(_ data: Data) -> String {
        HMAC<SHA256>.authenticationCode(
            for: data,
            using: textFingerprintKey
        ).map { String(format: "%02x", $0) }.joined()
    }

    private static func rounded(_ value: CGFloat) -> String {
        String(format: "%.3f", value)
    }
}

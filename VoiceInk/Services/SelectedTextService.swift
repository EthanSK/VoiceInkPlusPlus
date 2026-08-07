import Foundation
import ApplicationServices
import os
import SelectedTextKit

@MainActor
final class SelectedTextService {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SelectedTextService")
    private static let textManager = SelectedTextManager.shared
    private static let selectedTextStrategies: [TextStrategy] = [
        .accessibility,
        .appleScript
    ]

    static func fetchSelectedText() async -> String? {
        guard AXIsProcessTrusted() else {
            logger.debug("Accessibility is not trusted; selected text capture skipped")
            return nil
        }

        do {
            // Recording context capture can overlap an older Primary transcript paste.
            // SelectedTextKit's menu/shortcut strategies copy through NSPasteboard,
            // then restore their backup after any observed change. Our transcript write
            // can satisfy that poll and make the backup overwrite the exact payload just
            // before Command-V. Keep this path clipboard-free: AX covers native/Electron
            // selections and AppleScript covers supported browsers without mutating the
            // pasteboard. Paste delivery separately verifies its own lease as a backstop.
            return normalized(try await textManager.getSelectedText(strategies: selectedTextStrategies))
        } catch {
            logger.debug("SelectedTextKit failed to capture selected text: \(error, privacy: .public)")
            return nil
        }
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

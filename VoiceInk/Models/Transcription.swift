import Foundation
import SwiftData

enum TranscriptionStatus: String, Codable {
    case pending
    case recoverableDraft
    case completed
    case failed
    case canceled
    case canceledWithResult
}

@Model
final class Transcription {
    static let canceledTranscriptionText = "The transcription was canceled."

    var id: UUID = UUID()
    var text: String = ""
    var enhancedText: String?
    var timestamp: Date = Date()
    var duration: TimeInterval = 0
    var audioFileURL: String?
    /// Input device that actually started this recording. Optional preserves lightweight
    /// migration of existing History rows, whose source microphone was never stored.
    var inputDeviceName: String?
    var inputDeviceUID: String?
    var transcriptionModelName: String?
    var aiEnhancementModelName: String?
    var promptName: String?
    var transcriptionDuration: TimeInterval?
    var enhancementDuration: TimeInterval?
    var aiRequestSystemMessage: String?
    var aiRequestUserMessage: String?
    @Attribute(originalName: "powerModeName")
    var modeName: String?
    @Attribute(originalName: "powerModeEmoji")
    var modeEmoji: String?
    var transcriptionStatus: String?
    /// Last provider text shown in the realtime recorder HUD before capture ended.
    ///
    /// This is deliberately VoiceInk-local recovery data, not destination-app draft
    /// state. Persisting it beside `audioFileURL` means a clipboard-only triple-click,
    /// explicit no-delivery exit, provider failure, or app interruption still leaves
    /// both the original WAV and the words already visible to the user in History.
    var realtimeDraftText: String?
    /// Triple-click and explicit no-delivery exits promise a recoverable local draft.
    /// Automatic retention jobs must not delete their original WAV or history row;
    /// only a separate explicit user deletion may clear them.
    var preservesOriginalAudioForRecovery: Bool = false

    init(text: String,
         duration: TimeInterval,
         enhancedText: String? = nil,
         audioFileURL: String? = nil,
         recordingInputDevice: RecordingInputDeviceSnapshot? = nil,
         transcriptionModelName: String? = nil,
         aiEnhancementModelName: String? = nil,
         promptName: String? = nil,
         transcriptionDuration: TimeInterval? = nil,
         enhancementDuration: TimeInterval? = nil,
         aiRequestSystemMessage: String? = nil,
         aiRequestUserMessage: String? = nil,
         modeName: String? = nil,
         modeEmoji: String? = nil,
         realtimeDraftText: String? = nil,
         preservesOriginalAudioForRecovery: Bool = false,
         transcriptionStatus: TranscriptionStatus = .pending) {
        self.id = UUID()
        self.text = text
        self.enhancedText = enhancedText
        self.timestamp = Date()
        self.duration = duration
        self.audioFileURL = audioFileURL
        self.inputDeviceName = recordingInputDevice?.name
        self.inputDeviceUID = recordingInputDevice?.uid
        self.transcriptionModelName = transcriptionModelName
        self.aiEnhancementModelName = aiEnhancementModelName
        self.promptName = promptName
        self.transcriptionDuration = transcriptionDuration
        self.enhancementDuration = enhancementDuration
        self.aiRequestSystemMessage = aiRequestSystemMessage
        self.aiRequestUserMessage = aiRequestUserMessage
        self.modeName = modeName
        self.modeEmoji = modeEmoji
        self.realtimeDraftText = Self.normalizedDraftText(realtimeDraftText)
        self.preservesOriginalAudioForRecovery = preservesOriginalAudioForRecovery
        self.transcriptionStatus = transcriptionStatus.rawValue
    }

    var recoverableRealtimeDraftText: String? {
        Self.normalizedDraftText(realtimeDraftText)
    }

    /// History must never render a recoverable draft as a blank row while a final
    /// provider result is pending or was interrupted. A real final/canceled result
    /// remains authoritative; the realtime snapshot is the local fallback.
    var historyDisplayText: String {
        let stored = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty, stored != Self.canceledTranscriptionText {
            return stored
        }
        return recoverableRealtimeDraftText ?? text
    }

    func snapshotRealtimeDraft(_ text: String?) {
        realtimeDraftText = Self.normalizedDraftText(text)
    }

    private static func normalizedDraftText(_ text: String?) -> String? {
        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }

    func markAsCanceledTranscription(
        preservingRecoveredText recoveredText: String? = nil,
        duration: TimeInterval? = nil,
        modelName: String? = nil
    ) {
        let recovered = recoveredText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let recovered, !recovered.isEmpty {
            // Cancellation is still a no-delivery action, but words already produced
            // by the provider (or shown in the realtime HUD) remain useful. Preserve
            // exactly the clipboard value and give history a distinct status so this
            // can never be mistaken for an empty/no-result cancellation.
            text = recovered
            transcriptionStatus = TranscriptionStatus.canceledWithResult.rawValue
        } else {
            text = Self.canceledTranscriptionText
            transcriptionStatus = TranscriptionStatus.canceled.rawValue
        }
        enhancedText = nil
        if let duration {
            self.duration = duration
        }
        if let modelName {
            transcriptionModelName = modelName
        }
        transcriptionDuration = nil
        enhancementDuration = nil
        aiEnhancementModelName = nil
        promptName = nil
        aiRequestSystemMessage = nil
        aiRequestUserMessage = nil
    }
}

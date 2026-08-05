import SwiftUI

struct TranscriptionDetailView: View {
    let transcription: Transcription
    var onInfoTap: (() -> Void)?

    private var hasAudioFile: Bool {
        if let urlString = transcription.audioFileURL,
           let url = URL(string: urlString),
           FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        return false
    }

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                VStack(spacing: 16) {
                    MessageBubble(
                        label: transcription.transcriptionStatus == TranscriptionStatus.recoveredAfterInterruption.rawValue
                            ? "Recovered recording"
                            : transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                transcription.text == Transcription.canceledTranscriptionText
                            ? "Live draft at exit"
                            : "Original",
                        text: transcription.historyDisplayText,
                        isEnhanced: false
                    )

                    if let draft = transcription.recoverableRealtimeDraftText,
                       draft != transcription.historyDisplayText
                        .trimmingCharacters(in: .whitespacesAndNewlines) {
                        MessageBubble(
                            label: "Live draft at exit",
                            text: draft,
                            isEnhanced: false
                        )
                    }

                    if let enhancedText = transcription.enhancedText {
                        MessageBubble(
                            label: "Enhanced",
                            text: enhancedText,
                            isEnhanced: true
                        )
                    }
                }
                .padding(16)
            }

            if hasAudioFile, let urlString = transcription.audioFileURL,
               let url = URL(string: urlString) {
                VStack(spacing: 0) {
                    Divider()

                    if transcription.preservesOriginalAudioForRecovery {
                        Label(
                            "Saved locally — replay or retranscribe this original audio any time",
                            systemImage: "tray.and.arrow.down.fill"
                        )
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    }

                    AudioPlayerView(url: url, transcription: transcription, onInfoTap: onInfoTap)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                                .fill(AppTheme.Surface.materialCard)
                                .overlay {
                                    RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                                        .strokeBorder(AppTheme.Border.card, lineWidth: 1)
                                }
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                }
            }
        }
        .padding(.vertical, 12)
    }
}

private struct MessageBubble: View {
    let label: LocalizedStringKey
    let text: String
    let isEnhanced: Bool

    var body: some View {
        HStack(alignment: .bottom) {
            if isEnhanced { Spacer(minLength: 60) }

            VStack(alignment: isEnhanced ? .leading : .trailing, spacing: 4) {
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(AppTheme.Text.muted)
                    .padding(.horizontal, 12)

                ScrollView {
                    MarkdownContentView(
                        text,
                        fontSize: 14,
                        foregroundColor: AppTheme.Text.primary,
                        alignment: isEnhanced ? .leading : .trailing
                    )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .frame(maxHeight: 350)
                .background {
                    if isEnhanced {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                            .fill(AppTheme.Surface.subtle)
                            .overlay {
                                RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                                    .strokeBorder(AppTheme.Border.tint, lineWidth: 1)
                            }
                    } else {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                            .fill(AppTheme.Surface.materialCard)
                            .overlay(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                                    .strokeBorder(AppTheme.Border.subtle, lineWidth: 1)
                            )
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    CopyIconButton(textToCopy: text)
                        .padding(8)
                }
            }

            if !isEnhanced { Spacer(minLength: 60) }
        }
    }

}

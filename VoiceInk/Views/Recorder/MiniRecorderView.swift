import SwiftUI

struct MiniRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    @ObservedObject var stateProvider: S
    @ObservedObject var recorder: Recorder
    @ObservedObject var assistantSession: AssistantSession
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    // Cancel ("X"): discard the active recording/transcription with NO paste + resume
    // paused media. Routed up to RecorderUIManager.cancelRecording().
    let onCancelTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void

    // MARK: - Layout Constants

    private let controlBarHeight: CGFloat = 40
    private let compactWidth: CGFloat = 228
    private let expandedWidth: CGFloat = 344
    private let assistantWidth: CGFloat = 520
    private let compactCornerRadius: CGFloat = 20
    private let expandedCornerRadius: CGFloat = 14

    private var shouldShowPasteDestinationIndicator: Bool {
        switch stateProvider.recordingState {
        case .starting, .recording, .transcribing, .enhancing:
            return true
        case .idle, .busy:
            return false
        }
    }

    private var capsuleWidth: CGFloat {
        if hasAssistantResponse { return assistantWidth }
        if hasLiveTranscript { return expandedWidth }
        return shouldShowPasteDestinationIndicator ? 280 : compactWidth // Active layout also includes the exact build label immediately left of Stop.
    }

    // true when live transcript is streaming in during recording
    private var hasLiveTranscript: Bool {
        stateProvider.recordingState == .recording
            && !stateProvider.partialTranscript.isEmpty
    }

    private var hasAssistantResponse: Bool {
        assistantSession.isVisible
    }

    private var shouldShowCloseButton: Bool {
        hasAssistantResponse &&
            stateProvider.recordingState == .idle &&
            !assistantSession.isBusy
    }

    // The cancel ("X") button is reachable whenever there is something to abort:
    // while RECORDING (discard the audio) AND while a transcription is IN-FLIGHT
    // (.transcribing/.enhancing — abort delivery before it pastes) and during the
    // brief .starting handshake. Hidden at .idle/.busy where there's nothing to
    // cancel (the assistant close-button affordance covers idle dismissal instead).
    private var shouldShowCancelButton: Bool {
        switch stateProvider.recordingState {
        case .starting, .recording, .transcribing, .enhancing:
            return true
        case .idle, .busy:
            return false
        }
    }

    private var liveAssistantFollowUpText: String {
        guard stateProvider.recordingState == .recording else { return "" }
        return stateProvider.partialTranscript
    }

    // VIPP (skip-mode-processing feature): a Binding that reads/writes the OBSERVED
    // session's one-shot `skipPostProcessing` flag. The skip-processing toggle button uses
    // it to flip the flag in place. Because `stateProvider` is @ObservedObject (the live
    // RecordingSession), the get re-evaluates and the button's amber/subdued state updates
    // the instant it changes. Per-session + one-shot: see RecordingSession.skipPostProcessing.
    private var skipPostProcessingBinding: Binding<Bool> {
        Binding(
            get: { stateProvider.skipPostProcessing },
            set: { stateProvider.skipPostProcessing = $0 }
        )
    }

    private var controlBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                // Every shipped build increments CFBundleVersion. Keeping this
                // immediately left of Stop makes the running release obvious.
                RecorderVersionLabel()

                Group {
                    if shouldShowCloseButton {
                        RecorderCloseButton(action: onCloseTapped)
                    } else {
                        RecorderRecordButton(
                            recordingState: stateProvider.recordingState,
                            action: onRecordButtonTapped
                        )
                    }
                }

                // Cancel ("X") sits immediately to the RIGHT of the Stop/record control
                // so an abort is one glance + one tap away from Stop. Only shown while a
                // recording or in-flight transcription is cancellable (see
                // shouldShowCancelButton); collapses out otherwise so idle bars are unchanged.
                if shouldShowCancelButton {
                    RecorderCancelButton(action: onCancelTapped)
                        .transition(.opacity)

                    // VIPP (skip-mode-processing feature): the one-shot raw-transcript toggle
                    // sits immediately to the RIGHT of Cancel. Reuses the SAME visibility
                    // condition (shouldShowCancelButton) so it's available throughout the
                    // recording/in-flight window — the user can engage it DURING recording —
                    // and collapses out at idle/busy along with Cancel. Bound directly to the
                    // observed session's skipPostProcessing flag (no closure threading needed).
                    RecorderSkipProcessingButton(isEngaged: skipPostProcessingBinding)
                        .transition(.opacity)
                }
            }
            .padding(.leading, 10)
            .animation(.easeInOut(duration: 0.2), value: shouldShowCancelButton)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                // Mode belongs immediately to the LEFT of the waveform. The slot it
                // previously occupied on the right now shows the currently focused app.
                RecorderModeButton(
                    displayedMode: stateProvider.recorderDisplayMode,
                    buttonSize: 22,
                    padding: EdgeInsets()
                )

                RecorderStatusDisplay(
                    currentState: stateProvider.recordingState,
                    audioMeter: recorder.audioMeter
                )
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                CurrentFocusApplicationIndicator(
                    actionPulseID: stateProvider.currentFocusIconActionPulseID
                )

                if shouldShowPasteDestinationIndicator {
                    PasteDestinationIndicator(
                        target: stateProvider.pasteDestinationIndicatorTarget,
                        context: stateProvider.recordingState == .starting || stateProvider.recordingState == .recording ? .nextTrackStop : .pendingPaste,
                        actionPulseID: stateProvider.lockedDestinationIconActionPulseID
                    ) // Do not hide this at stop: the same per-session icon confirms VoiceInk still owns the target while transcription is loading, and updates if Next Track retargets it.
                        .transition(.opacity)
                }
            }
            .padding(.trailing, 12)
        }
        .frame(height: controlBarHeight)
    }

    private var transcriptSection: some View {
        VStack(spacing: 0) {
            if hasLiveTranscript {
                LiveTranscriptView(text: stateProvider.partialTranscript)
                Divider().background(Color.white.opacity(0.15))
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasAssistantResponse {
                AssistantPanelView(
                    session: assistantSession,
                    liveFollowUpText: liveAssistantFollowUpText,
                    onSend: onAssistantFollowUp
                )
                Divider().background(Color.white.opacity(0.15))
            } else {
                transcriptSection
            }
            controlBar
        }
        .frame(width: capsuleWidth)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: hasLiveTranscript || hasAssistantResponse ? expandedCornerRadius : compactCornerRadius, style: .continuous))
        .animation(.easeInOut(duration: 0.3), value: hasLiveTranscript)
        .animation(.easeInOut(duration: 0.3), value: hasAssistantResponse)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

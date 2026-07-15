import SwiftUI

struct NotchRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    @ObservedObject var stateProvider: S
    @ObservedObject var recorder: Recorder
    @ObservedObject var assistantSession: AssistantSession
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    // Cancel ("X"): discard the active recording/transcription with NO paste + resume
    // paused media. Routed up to RecorderUIManager.cancelRecording().
    let onCancelTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void

    // MARK: - Display State

    private enum DisplayState: Equatable {
        case collapsed
        case active
        case liveText
        case assistant
    }

    private var displayState: DisplayState {
        if assistantSession.isVisible {
            return .assistant
        }

        switch stateProvider.recordingState {
        case .recording:
            let shouldShowLive = !stateProvider.partialTranscript.isEmpty
            return shouldShowLive ? .liveText : .active
        case .transcribing, .enhancing:
            return .active
        default:
            return .collapsed
        }
    }

    // MARK: - Layout Constants

    private let recordingSideExpansion: CGFloat = 180
    private let transcriptSideExpansion: CGFloat = 180
    private let assistantSideExpansion: CGFloat = 230
    private let activeHeightBonus: CGFloat = 6
    private let transcriptPanelHeight: CGFloat = 57
    private let assistantPanelHeight: CGFloat = 320

    private var mainRowHeight: CGFloat { notchHeight + activeHeightBonus }

    // MARK: - Pill Dimensions

    private var pillWidth: CGFloat {
        switch displayState {
        case .collapsed: return notchWidth
        case .active:    return notchWidth + recordingSideExpansion * 2
        case .liveText:  return notchWidth + transcriptSideExpansion * 2
        case .assistant: return notchWidth + assistantSideExpansion * 2
        }
    }

    private var pillHeight: CGFloat {
        switch displayState {
        case .collapsed: return 0
        case .active:    return mainRowHeight
        case .liveText:  return mainRowHeight + transcriptPanelHeight
        case .assistant: return mainRowHeight + assistantPanelHeight
        }
    }

    private var sideExpansion: CGFloat {
        switch displayState {
        case .liveText:
            return transcriptSideExpansion
        case .assistant:
            return assistantSideExpansion
        case .active, .collapsed:
            return recordingSideExpansion
        }
    }

    private var sideEdgePadding: CGFloat {
        displayState == .liveText || displayState == .assistant ? 20 : 16
    }

    private var shouldShowCloseButton: Bool {
        displayState == .assistant &&
            stateProvider.recordingState == .idle &&
            !assistantSession.isBusy
    }

    private var shouldShowPasteDestinationIndicator: Bool {
        switch stateProvider.recordingState {
        case .starting, .recording, .transcribing, .enhancing:
            return true
        case .idle, .busy:
            return false
        }
    }

    // Cancel ("X") visibility — mirrors the mini panel: reachable while RECORDING
    // (discard audio) and while a transcription is IN-FLIGHT (.transcribing/.enhancing,
    // abort before paste) plus the brief .starting handshake. Hidden at .idle/.busy.
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

    // VIPP (skip-mode-processing feature): Binding to the OBSERVED session's one-shot
    // `skipPostProcessing` flag, used by the skip-processing toggle next to Cancel. See the
    // mirror in MiniRecorderView for the full rationale (per-session, one-shot, re-renders
    // live because stateProvider is the @ObservedObject RecordingSession).
    private var skipPostProcessingBinding: Binding<Bool> {
        Binding(
            get: { stateProvider.skipPostProcessing },
            set: { stateProvider.skipPostProcessing = $0 }
        )
    }

    // MARK: - Animation

    private let expandAnimation = Animation.spring(response: 0.42, dampingFraction: 0.80)
    private let collapseAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0)

    private var pillAnimation: Animation {
        displayState == .collapsed ? collapseAnimation : expandAnimation
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            pill.position(x: geo.size.width / 2, y: pillHeight / 2)
        }
        .animation(pillAnimation, value: displayState)
    }

    // MARK: - Pill

    private var pill: some View {
        VStack(spacing: 0) {
            mainRow
            liveTextPanel
            assistantPanel
        }
        .frame(width: pillWidth, height: pillHeight)
        .background(Color.black)
        .clipShape(
            NotchShape(
                topCornerRadius: displayState == .liveText ? 12 : 8,
                bottomCornerRadius: displayState == .liveText || displayState == .assistant ? 22 : 16
            )
        )
    }

    // MARK: - Main Row

    private var mainRow: some View {
        ZStack {
            Color.clear

            HStack(spacing: 14) {
                // Mirrors the mini recorder: the exact running build sits
                // immediately left of the Stop control on every monitor.
                RecorderVersionLabel()

                if shouldShowCloseButton {
                    RecorderCloseButton(action: onCloseTapped)
                } else {
                    RecorderRecordButton(
                        recordingState: stateProvider.recordingState,
                        action: onRecordButtonTapped
                    )
                }

                // Cancel ("X") immediately to the right of the Stop/record control so an
                // abort is one tap from Stop. Only while a recording/transcription is
                // cancellable (see shouldShowCancelButton); collapses out at idle/busy so
                // the notch pill's normal layout is unchanged.
                if shouldShowCancelButton {
                    RecorderCancelButton(action: onCancelTapped)
                        .transition(.opacity)

                    // VIPP (skip-mode-processing feature): one-shot raw-transcript toggle to
                    // the RIGHT of Cancel. Same visibility window as Cancel (engage DURING
                    // recording / in-flight), bound to the observed session's flag. Mirrors
                    // the mini panel exactly so behaviour is identical across recorder styles.
                    RecorderSkipProcessingButton(isEngaged: skipPostProcessingBinding)
                        .transition(.opacity)
                }

                RecorderModeButton(
                    displayedMode: stateProvider.recorderDisplayMode,
                    buttonSize: 20,
                    padding: EdgeInsets()
                )
                Spacer(minLength: 0)
            }
            .animation(.easeInOut(duration: 0.2), value: shouldShowCancelButton)
            .padding(.leading, sideEdgePadding)
            .frame(width: sideExpansion)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(displayState != .collapsed ? 1 : 0)
            .animation(
                displayState != .collapsed ? expandAnimation.delay(0.09) : collapseAnimation,
                value: displayState
            )

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                RecorderStatusDisplay(
                    currentState: stateProvider.recordingState,
                    audioMeter: recorder.audioMeter,
                    menuBarHeight: notchHeight
                )

                CurrentFocusApplicationIndicator(
                    actionPulseID: stateProvider.currentFocusIconActionPulseID
                )
                    .padding(.leading, 8)

                if shouldShowPasteDestinationIndicator {
                    PasteDestinationIndicator(
                        target: stateProvider.pasteDestinationIndicatorTarget,
                        context: stateProvider.recordingState == .starting || stateProvider.recordingState == .recording ? .nextTrackStop : .pendingPaste,
                        actionPulseID: stateProvider.lockedDestinationIconActionPulseID
                    ) // Mirrors the mini capsule and stays attached to this session until paste succeeds or visibly fails.
                        .padding(.leading, 8)
                        .transition(.opacity)
                }
            }
            .padding(.trailing, sideEdgePadding)
            .frame(width: sideExpansion)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(displayState != .collapsed ? 1 : 0)
            .animation(
                displayState != .collapsed ? expandAnimation.delay(0.09) : collapseAnimation,
                value: displayState
            )
        }
        .frame(height: mainRowHeight)
    }

    // MARK: - Live Text Panel

    private var liveTextPanel: some View {
        VStack(spacing: 0) {
            if displayState == .liveText {
                Divider().background(Color.white.opacity(0.15))
                LiveTranscriptView(text: stateProvider.partialTranscript)
                    .padding(.horizontal, 8)
            }
        }
        .frame(height: displayState == .liveText ? transcriptPanelHeight : 0)
        .clipped()
    }

    private var assistantPanel: some View {
        VStack(spacing: 0) {
            if displayState == .assistant {
                Divider().background(Color.white.opacity(0.15))
                AssistantPanelView(
                    session: assistantSession,
                    liveFollowUpText: liveAssistantFollowUpText,
                    onSend: onAssistantFollowUp
                )
            }
        }
        .frame(height: displayState == .assistant ? assistantPanelHeight : 0)
        .clipped()
    }
}

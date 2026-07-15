import Foundation

// Protocol for objects that provide live recorder state to the UI.
@MainActor
protocol RecorderStateProvider: AnyObject {
    var recordingState: RecordingState { get }
    var partialTranscript: String { get }
    var pasteDestinationIndicatorTarget: FocusLockService.Target? { get } // While recording this previews the Next Track destination; after stop it follows the session's actual pending paste target until delivery finishes.
    var iconActionPulse: RecorderIconActionPulse? { get } // Primary normal stop flashes the left/current icon; either accepted Next-button route flashes the right/locked icon.
    var recorderDisplayMode: ModeConfig? { get } // Real sessions expose their frozen destination Mode; only the assistant-only engine fallback may expose the global Mode.

    // VIPP (skip-mode-processing feature): the per-session, one-shot "skip post-processing
    // for THIS recording" flag. SETTABLE here so the recorder's toggle button (which is
    // bound to whatever RecorderStateProvider its card observes — normally the live
    // RecordingSession) can flip it DURING recording. Reading/writing it through the
    // protocol keeps the generic Mini/NotchRecorderView<S: RecorderStateProvider> able to
    // drive the button's on/off state directly off the observed object, mirroring how the
    // existing per-session-observation pattern works (no stateless closure threading needed).
    //
    // Semantics (see RecordingSession.skipPostProcessing for the authoritative doc):
    //   • true  → this single dictation pastes the RAW transcript: NO AI enhancement and
    //             NO mode custom-command/script. It does NOT change the user's default mode.
    //   • false → normal behaviour (the active Mode's full post-processing runs).
    // It is per-session + one-shot: the next recording starts a fresh RecordingSession with
    // the flag back at false.
    var skipPostProcessing: Bool { get set }
}

extension RecorderStateProvider {
    var currentFocusIconActionPulseID: UUID? {
        guard let pulse = iconActionPulse, pulse.icon == .currentFocus else { return nil }
        return pulse.id
    }

    var lockedDestinationIconActionPulseID: UUID? {
        guard let pulse = iconActionPulse, pulse.icon == .lockedDestination else { return nil }
        return pulse.id
    }
}

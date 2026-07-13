import Foundation

// Protocol for objects that provide live recorder state to the UI.
@MainActor
protocol RecorderStateProvider: AnyObject {
    var recordingState: RecordingState { get }
    var partialTranscript: String { get }
    var recordingStartFocusedInput: FocusLockService.Target? { get } // The recorder capsule displays this per-session target so the user can always see where a Next Track stop will paste.

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

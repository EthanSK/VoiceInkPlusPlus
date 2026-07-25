import Foundation

enum RecordingState: Equatable {
    case idle
    case starting
    case recording
    // The recording session still owns the open WAV/streaming session, but AUHAL
    // capture is stopped. Keeping this distinct from `.idle` prevents a pause from
    // becoming a new recording or a destination-route transition.
    case paused
    case transcribing
    case enhancing
    case busy

    var isRecordingOrPaused: Bool {
        self == .recording || self == .paused
    }
}

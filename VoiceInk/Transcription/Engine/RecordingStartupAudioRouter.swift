import Foundation
import os

/// Preserves PCM order while one recording changes from startup buffering to its live
/// streaming callback.
///
/// The recorder keeps this one callback for the whole handoff. Replacing the recorder's
/// callback directly is unsafe: the audio thread can retain the old closure while the main
/// thread drains its array, or a newer live chunk can overtake buffered audio. This router
/// owns both states under one lock, so every older buffered chunk reaches the stream before
/// a newer live chunk can observe the destination.
final class RecordingStartupAudioRouter: @unchecked Sendable {
    enum ActivationResult: Equatable {
        case connected(replayedChunks: Int, replayedBytes: Int)
        case fallbackRequired(droppedChunks: Int, droppedBytes: Int)
        case closed
    }

    /// Startup normally lasts well under a second. Thirty seconds is deliberately generous
    /// while bounding a wedged Mode/context lookup to less than 1 MB at 16 kHz mono PCM16.
    static let defaultMaximumBufferedBytes = 32_000 * 30

    private struct State {
        var bufferedChunks: [Data] = []
        var bufferedBytes = 0
        var liveDestination: ((Data) -> Void)?
        var isClosed = false
        var didOverflow = false
        var droppedChunks = 0
        var droppedBytes = 0
    }

    private let maximumBufferedBytes: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(maximumBufferedBytes: Int = defaultMaximumBufferedBytes) {
        self.maximumBufferedBytes = max(0, maximumBufferedBytes)
    }

    /// Receive one recorder chunk. The live callback is invoked after releasing the router
    /// lock on the steady-state path; activation itself keeps the lock while replaying, so a
    /// concurrent audio callback cannot overtake that replay.
    func receive(_ data: Data) {
        let destination = state.withLock { state -> ((Data) -> Void)? in
            guard !state.isClosed else { return nil }
            if let liveDestination = state.liveDestination {
                return liveDestination
            }

            guard !state.didOverflow,
                  data.count <= maximumBufferedBytes - state.bufferedBytes else {
                // Once startup exceeds the bound, realtime is no longer complete. Release
                // retained PCM and force this recording through its complete WAV fallback;
                // silently dropping only the oldest audio would create a plausible but wrong
                // live transcript.
                state.didOverflow = true
                state.droppedChunks += state.bufferedChunks.count + 1
                state.droppedBytes += state.bufferedBytes + data.count
                state.bufferedChunks.removeAll(keepingCapacity: false)
                state.bufferedBytes = 0
                return nil
            }

            state.bufferedChunks.append(data)
            state.bufferedBytes += data.count
            return nil
        }

        destination?(data)
    }

    /// Atomically replay startup PCM and switch every later chunk to the live stream.
    /// Returns a fallback result if the bounded startup buffer could not retain the entire
    /// recording prefix; callers must then use the complete WAV instead of partial realtime.
    func activate(_ destination: @escaping (Data) -> Void) -> ActivationResult {
        state.withLock { state in
            guard !state.isClosed else { return .closed }
            guard !state.didOverflow else {
                state.isClosed = true
                return .fallbackRequired(
                    droppedChunks: state.droppedChunks,
                    droppedBytes: state.droppedBytes
                )
            }

            let replayedChunks = state.bufferedChunks.count
            let replayedBytes = state.bufferedBytes
            for chunk in state.bufferedChunks {
                destination(chunk)
            }
            state.bufferedChunks.removeAll(keepingCapacity: false)
            state.bufferedBytes = 0
            state.liveDestination = destination
            return .connected(
                replayedChunks: replayedChunks,
                replayedBytes: replayedBytes
            )
        }
    }

    func close() {
        state.withLock { state in
            state.isClosed = true
            state.liveDestination = nil
            state.bufferedChunks.removeAll(keepingCapacity: false)
            state.bufferedBytes = 0
        }
    }
}

import CryptoKit
import Foundation

/// Immutable identity for one stopped recording's queued pipeline work.
///
/// The session, SwiftData record, and audio file are intentionally bound together
/// before the job enters the serial queue. A later recording may change global Mode,
/// focus, recorder callbacks, or queue position, but it cannot replace any member of
/// this identity. Only the audio basename and opaque IDs are written to diagnostics.
struct TranscriptionJobIdentity: Hashable {
    let generation: UInt64
    let enqueueSequence: UInt64
    let recordingSessionID: UUID
    let transcriptionID: UUID
    let audioURL: URL

    var logDescription: String {
        "generation=\(generation) sequence=\(enqueueSequence) "
            + "recordingSessionID=\(recordingSessionID.uuidString) "
            + "transcriptionID=\(transcriptionID.uuidString) "
            + "audioFile=\(audioURL.lastPathComponent)"
    }
}

/// Pure state used by the runtime queue and deterministic tests.
///
/// Besides making reset a generation boundary, this rejects every accidental
/// many-to-one mapping: one session, transcription record, or exact audio URL may
/// belong to only one pending job. That turns a potential old-result race into a
/// visible enqueue failure instead of letting the wrong audio reach delivery.
struct TranscriptionJobRegistry {
    private(set) var generation: UInt64 = 1
    private(set) var nextEnqueueSequence: UInt64 = 1
    private var identitiesByTranscriptionID: [UUID: TranscriptionJobIdentity] = [:]

    mutating func register(
        recordingSessionID: UUID,
        transcriptionID: UUID,
        audioURL: URL
    ) -> TranscriptionJobIdentity? {
        let normalizedAudioURL = audioURL.standardizedFileURL
        guard identitiesByTranscriptionID[transcriptionID] == nil,
              !identitiesByTranscriptionID.values.contains(where: {
                  $0.recordingSessionID == recordingSessionID
                      || $0.audioURL.standardizedFileURL == normalizedAudioURL
              }) else {
            return nil
        }

        let identity = TranscriptionJobIdentity(
            generation: generation,
            enqueueSequence: nextEnqueueSequence,
            recordingSessionID: recordingSessionID,
            transcriptionID: transcriptionID,
            audioURL: normalizedAudioURL
        )
        nextEnqueueSequence &+= 1
        identitiesByTranscriptionID[transcriptionID] = identity
        return identity
    }

    func contains(_ identity: TranscriptionJobIdentity) -> Bool {
        identity.generation == generation
            && identitiesByTranscriptionID[identity.transcriptionID] == identity
    }

    mutating func remove(_ identity: TranscriptionJobIdentity) {
        guard identitiesByTranscriptionID[identity.transcriptionID] == identity else {
            return
        }
        identitiesByTranscriptionID.removeValue(forKey: identity.transcriptionID)
    }

    mutating func invalidateAll() {
        generation &+= 1
        identitiesByTranscriptionID.removeAll()
    }
}

/// Synchronous reservation for the asynchronous record-start boundary.
///
/// `toggleRecord` used to schedule `startNewSession` in a new MainActor task before
/// any RecordingSession existed. Two rapid start events could therefore both observe
/// "no active recording" and later create two mic owners. Reserving first makes the
/// one-active-recording invariant true across that scheduling gap as well.
struct RecordingStartReservation {
    private(set) var pendingID: UUID?

    mutating func reserve(id: UUID = UUID()) -> UUID? {
        guard pendingID == nil else { return nil }
        pendingID = id
        return id
    }

    mutating func consume(_ id: UUID) -> Bool {
        guard pendingID == id else { return false }
        pendingID = nil
        return true
    }

    mutating func cancel(_ id: UUID) {
        guard pendingID == id else { return }
        pendingID = nil
    }

    mutating func invalidate() {
        pendingID = nil
    }
}

/// MainActor FIFO scheduler for transcription jobs.
///
/// Every task is retained, not only the tail, so a reset cancels the running job and
/// every waiter. A waiting task always rechecks cancellation and registry membership
/// after the previous tail completes; cancellation of `Task<Void, Never>` does not
/// make `await previous.value` throw by itself.
@MainActor
final class SerialTranscriptionJobQueue {
    typealias MembershipCheck = @MainActor (TranscriptionJobIdentity) -> Bool
    typealias Operation = @MainActor (TranscriptionJobIdentity) async -> Void
    typealias Discard = @MainActor (TranscriptionJobIdentity) -> Void

    private var tail: Task<Void, Never>?
    private var tailIdentity: TranscriptionJobIdentity?
    private var tasks: [TranscriptionJobIdentity: Task<Void, Never>] = [:]
    private var resetDrainBarrier: Task<Void, Never>?
    private var resetDrainBarrierID: UUID?

    func enqueue(
        _ identity: TranscriptionJobIdentity,
        isCurrent: @escaping MembershipCheck,
        onDiscard: @escaping Discard,
        operation: @escaping Operation
    ) {
        // A reset cancels old jobs, but cancellation does not synchronously unwind an
        // in-flight provider request. When there is no current-generation tail, keep a
        // new job behind the reset barrier so two generations can never overlap on the
        // shared Whisper/FluidAudio resources.
        let previousTail = tail ?? resetDrainBarrier
        let task = Task { @MainActor [weak self] in
            await previousTail?.value
            guard let self else { return }
            guard !Task.isCancelled, isCurrent(identity) else {
                onDiscard(identity)
                self.finish(identity)
                return
            }

            await operation(identity)
            self.finish(identity)
        }
        tasks[identity] = task
        tail = task
        tailIdentity = identity
    }

    @discardableResult
    func cancelAll() -> [Task<Void, Never>] {
        let canceledTasks = Array(tasks.values)
        for task in canceledTasks {
            task.cancel()
        }
        tasks.removeAll()
        tail = nil
        tailIdentity = nil

        // Do not expose an empty tail while cancelled work is still unwinding. A later
        // enqueue awaits this non-cancelled barrier before it can start. Chaining the
        // prior barrier also makes repeated resets safe without creating a gap.
        let priorBarrier = resetDrainBarrier
        let barrierID = UUID()
        resetDrainBarrierID = barrierID
        resetDrainBarrier = Task { @MainActor [weak self] in
            await priorBarrier?.value
            for task in canceledTasks {
                await task.value
            }
            guard let self, self.resetDrainBarrierID == barrierID else { return }
            self.resetDrainBarrier = nil
            self.resetDrainBarrierID = nil
        }
        return canceledTasks
    }

    func waitUntilIdle() async {
        if let tail {
            await tail.value
        } else {
            await resetDrainBarrier?.value
        }
    }

    private func finish(_ identity: TranscriptionJobIdentity) {
        tasks.removeValue(forKey: identity)
        if tailIdentity == identity {
            tail = nil
            tailIdentity = nil
        }
    }
}

enum TranscriptionLineageDigest {
    /// Short SHA-256 prefix for correlating results without logging dictated text.
    static func make(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

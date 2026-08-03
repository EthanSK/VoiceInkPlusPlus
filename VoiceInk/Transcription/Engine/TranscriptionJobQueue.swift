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

/// Prevents an older completed transcription from mutating the foreground input while
/// a newer recording owns (or is about to own) the microphone.
///
/// Provider finalization is still allowed to finish in the background. Only the final
/// user-visible delivery side effect waits. Owners begin at the synchronous start
/// reservation, transfer atomically to the created `RecordingSession`, and end only
/// after that capture has stopped/canceled and its immutable job has been enqueued.
/// This closes the few-millisecond start-handshake gap without canceling either result
/// or weakening FIFO delivery.
@MainActor
final class ActiveRecordingDeliveryBarrier {
    private(set) var activeCaptureOwners = Set<UUID>()
    private(set) var activeDeliveryOwners = Set<UUID>()
    private var stateChangeWaiters: [CheckedContinuation<Void, Never>] = []

    var isDeliveryBlocked: Bool {
        !activeCaptureOwners.isEmpty
    }

    var isCaptureStartBlocked: Bool {
        !activeDeliveryOwners.isEmpty
    }

    func beginCapture(owner: UUID) {
        activeCaptureOwners.insert(owner)
    }

    @discardableResult
    func transferCapture(from reservation: UUID, to session: UUID) -> Bool {
        // A missing reservation means lifecycle ownership was already reset or
        // corrupted. Never manufacture a session owner in that state: it could not be
        // paired reliably with the original start and would block delivery forever.
        guard activeCaptureOwners.contains(reservation),
              !activeCaptureOwners.contains(session) else {
            return false
        }
        activeCaptureOwners.remove(reservation)
        activeCaptureOwners.insert(session)
        return true
    }

    func endCapture(owner: UUID) {
        guard activeCaptureOwners.remove(owner) != nil else { return }
        if activeCaptureOwners.isEmpty {
            signalStateChange()
        }
    }

    /// Wake blocked jobs so they can observe per-session cancellation or stale lineage
    /// without falsely declaring the still-active capture finished.
    func notifyStateChange() {
        signalStateChange()
    }

    func reset() {
        activeCaptureOwners.removeAll()
        activeDeliveryOwners.removeAll()
        signalStateChange()
    }

    /// The synchronous reservation is already an active capture owner when this runs,
    /// so no later delivery can overtake it. We wait only for a delivery that acquired
    /// the opposite lease first.
    func waitUntilCaptureMayStart(
        while shouldContinueWaiting: () -> Bool
    ) async -> Bool {
        while isCaptureStartBlocked && shouldContinueWaiting() {
            await withCheckedContinuation { continuation in
                stateChangeWaiters.append(continuation)
            }
        }
        return shouldContinueWaiting() && !isCaptureStartBlocked
    }

    /// Atomically waits for every capture owner, then acquires the delivery side of
    /// the lease before returning. A new Primary start can reserve immediately after
    /// this, but its microphone handshake must wait for `releaseDelivery`.
    func acquireDelivery(
        owner: UUID,
        while shouldContinueWaiting: () -> Bool
    ) async -> Bool {
        while isDeliveryBlocked && shouldContinueWaiting() {
            await withCheckedContinuation { continuation in
                stateChangeWaiters.append(continuation)
            }
        }
        guard shouldContinueWaiting(), !isDeliveryBlocked else { return false }
        activeDeliveryOwners.insert(owner)
        return true
    }

    func releaseDelivery(owner: UUID) {
        guard activeDeliveryOwners.remove(owner) != nil else { return }
        if activeDeliveryOwners.isEmpty {
            signalStateChange()
        }
    }

    private func signalStateChange() {
        let waiters = stateChangeWaiters
        stateChangeWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
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

/// Shared Whisper/FluidAudio state is process-wide even though recording jobs are not.
/// Keep the small ownership decision pure so overlap regressions are independently
/// testable: speculative preload is safe only for the sole live session, and cleanup
/// is safe only after the retiring owner is still current and no session remains.
enum SharedTranscriptionResourcePolicy {
    static func allowsSpeculativePreload(liveSessionCount: Int) -> Bool {
        liveSessionCount == 1
    }

    static func allowsCleanup(
        liveSessionCount: Int,
        retiringOwnerIsCurrent: Bool
    ) -> Bool {
        retiringOwnerIsCurrent && liveSessionCount == 0
    }
}

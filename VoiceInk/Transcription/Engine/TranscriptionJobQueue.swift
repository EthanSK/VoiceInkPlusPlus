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

    var isEmpty: Bool {
        identitiesByTranscriptionID.isEmpty
    }

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

    /// Returns every still-registered successor in immutable FIFO order.
    ///
    /// Queue-tail auto-send must inspect the complete retained registry, not the
    /// scheduler's single `tail` reference: cancellation is cooperative and every
    /// earlier task remains in flight until it actually exits. Returning identities
    /// only from the current generation also keeps reset from joining two unrelated
    /// recording cohorts.
    func newerIdentities(
        after identity: TranscriptionJobIdentity
    ) -> [TranscriptionJobIdentity] {
        guard contains(identity) else { return [] }
        return identitiesByTranscriptionID.values
            .filter {
                $0.generation == identity.generation
                    && $0.enqueueSequence > identity.enqueueSequence
            }
            .sorted { $0.enqueueSequence < $1.enqueueSequence }
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

/// One newer FIFO job as seen at an older Primary delivery boundary.
///
/// Eligibility is deliberately computed by `VoiceInkEngine`, where the job's live
/// session route, completion policy, cancel state, and output action are available.
/// Keeping the reducer below independent of sessions makes A/B/C behavior and cohort
/// breaks deterministic in tests.
struct PrimaryQueuedAutoSendCandidate: Equatable {
    let enqueueSequence: UInt64
    let isEligiblePrimaryPaste: Bool
}

/// The effective key for one Primary paste plus privacy-safe queue diagnostics.
enum PrimaryAutoSendSuppressionReason: String, Equatable {
    case none
    case queuedSuccessor
    case pendingRecordingStart
    case currentCanceled
}

struct PrimaryQueuedAutoSendResolution: Equatable {
    let originalKey: AutoSendKey
    let effectiveKey: AutoSendKey
    let queuedTailSequence: UInt64?
    let consecutiveSuccessorCount: Int
    let suppressionReason: PrimaryAutoSendSuppressionReason

    var isSuppressed: Bool {
        suppressionReason != .none
    }

    var isQueuedSuppression: Bool {
        suppressionReason == .queuedSuccessor
            || suppressionReason == .pendingRecordingStart
    }

    static func unchanged(_ key: AutoSendKey) -> Self {
        Self(
            originalKey: key,
            effectiveKey: key,
            queuedTailSequence: nil,
            consecutiveSuccessorCount: 0,
            suppressionReason: .none
        )
    }

    static func canceledCurrent(_ key: AutoSendKey) -> Self {
        Self(
            originalKey: key,
            effectiveKey: .none,
            queuedTailSequence: nil,
            consecutiveSuccessorCount: 0,
            suppressionReason: .currentCanceled
        )
    }

    static func pendingRecordingStart(_ key: AutoSendKey) -> Self {
        Self(
            originalKey: key,
            effectiveKey: .none,
            queuedTailSequence: nil,
            consecutiveSuccessorCount: 0,
            suppressionReason: .pendingRecordingStart
        )
    }
}

/// Gives one configured auto-send to the tail of a consecutive Primary paste cohort.
///
/// Example: A/B/C normal Primary jobs resolve to none/none/configured-key. An exact
/// Next route, clipboard-only recovery, cancellation, raw/skip delivery, assistant
/// follow-up, response, or custom command breaks the cohort rather than suppressing an
/// unrelated destination's action. If a successor fails only after an older paste has
/// already been suppressed, fail safely: never issue a delayed Return to an unverified
/// current input. The text remains pasted and unsent for the user to submit manually.
enum PrimaryQueuedAutoSendPolicy {
    static func resolve(
        originalKey: AutoSendKey,
        currentIsEligiblePrimaryPaste: Bool,
        newerCandidates: [PrimaryQueuedAutoSendCandidate],
        newerRecordingStartPending: Bool = false
    ) -> PrimaryQueuedAutoSendResolution {
        guard currentIsEligiblePrimaryPaste else {
            return .unchanged(originalKey)
        }

        let consecutiveSuccessors = newerCandidates.prefix {
            $0.isEligiblePrimaryPaste
        }
        guard let tail = consecutiveSuccessors.last else {
            // If another registered route already follows this job, that route owns
            // the cohort break even when a still-later recording start is waiting.
            // With no registered successor, the synchronous start reservation itself
            // is enough to prove Ethan began a continuation before Return-down.
            if newerCandidates.isEmpty,
               newerRecordingStartPending,
               originalKey.isEnabled {
                return .pendingRecordingStart(originalKey)
            }
            return .unchanged(originalKey)
        }

        // A tail Mode with no auto-send remains paste-only, but retain cohort
        // metadata so an older outstanding suppression is not cleared before that
        // tail actually reaches its own successful Primary paste boundary.
        guard originalKey.isEnabled else {
            return PrimaryQueuedAutoSendResolution(
                originalKey: originalKey,
                effectiveKey: originalKey,
                queuedTailSequence: tail.enqueueSequence,
                consecutiveSuccessorCount: consecutiveSuccessors.count,
                suppressionReason: .none
            )
        }

        return PrimaryQueuedAutoSendResolution(
            originalKey: originalKey,
            effectiveKey: .none,
            queuedTailSequence: tail.enqueueSequence,
            consecutiveSuccessorCount: consecutiveSuccessors.count,
            suppressionReason: .queuedSuccessor
        )
    }
}

/// Tracks only whether an earlier successful Primary paste is awaiting the cohort
/// tail's delivery. It never owns or emits a key event. If that predicted tail later
/// cancels, fails, or retargets, draining returns the unresolved predecessors so the
/// engine can warn; a compensating Return would be unsafe because Primary saved no
/// exact input.
struct PrimaryQueuedAutoSendTracker {
    private(set) var suppressedSequences = Set<UInt64>()
    private(set) var expectedTailSequence: UInt64?

    mutating func observeSuccessfulPrimaryPaste(
        sequence: UInt64,
        resolution: PrimaryQueuedAutoSendResolution
    ) {
        if resolution.isQueuedSuppression {
            suppressedSequences.insert(sequence)
            if let queuedTailSequence = resolution.queuedTailSequence {
                expectedTailSequence = max(
                    expectedTailSequence ?? queuedTailSequence,
                    queuedTailSequence
                )
            }
            return
        }

        // A successful later Primary paste whose own Mode intentionally disables
        // auto-send is still the cohort tail; no key was promised for that Mode, so
        // do not misreport the earlier queue suppression as a failure.
        if !resolution.originalKey.isEnabled,
           resolution.consecutiveSuccessorCount == 0,
           suppressedSequences.contains(where: { $0 < sequence }) {
            reset()
        }
    }

    mutating func observePrimaryAutoSendIssued(sequence: UInt64) {
        guard suppressedSequences.contains(where: { $0 < sequence }) else {
            return
        }
        reset()
    }

    mutating func takeUnresolvedIfQueueDrained(
        hasOutstandingSuccessor: Bool
    ) -> [UInt64] {
        guard !hasOutstandingSuccessor, !suppressedSequences.isEmpty else {
            return []
        }
        let unresolved = suppressedSequences.sorted()
        reset()
        return unresolved
    }

    mutating func reset() {
        suppressedSequences.removeAll()
        expectedTailSequence = nil
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

enum TranscriptionDeliveryLeasePolicy: Equatable {
    /// Commands, responses, exact Next destinations, raw/skip delivery, and every
    /// other non-cohort side effect remain mutually exclusive with active capture.
    case exclusive

    /// A consecutive normal Primary result may paste while the next recording owns
    /// the microphone. Its Return is decided later and suppressed by the queue-tail
    /// policy, so A can appear during B without prematurely submitting the cohort.
    case primaryPasteDuringCapture
}

/// Coordinates an older completed transcription with a newer microphone capture.
///
/// Provider finalization is always allowed to finish in the background. Most final
/// side effects still wait for capture to end. The deliberate exception is a normal
/// Primary FIFO-cohort paste: it may cross the capture boundary, while the later
/// last-safe auto-send resolver suppresses Return because a capture owner exists.
/// Owners begin at the synchronous start reservation, transfer atomically to the
/// created `RecordingSession`, and end only after capture stops/cancels and its
/// immutable job is enqueued. This closes the start-handshake gap without dropping
/// either transcript or letting an earlier partial cohort submit.
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

    /// The exact delivery-first race that originally justified the synchronous
    /// recording-start reservation. Keep this narrow probe for the regression test:
    /// production Return suppression deliberately uses the broader
    /// `isDeliveryBlocked`, because an already-started capture is continuation intent too.
    var hasCaptureWaitingBehindDelivery: Bool {
        !activeCaptureOwners.isEmpty && !activeDeliveryOwners.isEmpty
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

    /// Atomically applies the requested delivery policy and acquires the delivery side
    /// of the lease. Exclusive work waits for every capture owner. A normal Primary
    /// cohort paste may acquire while capture is live; a still-later start reservation
    /// nevertheless waits behind this short paste lease, and the current capture owner
    /// remains visible to the last-safe Return suppression decision.
    func acquireDelivery(
        owner: UUID,
        policy: TranscriptionDeliveryLeasePolicy = .exclusive,
        while shouldContinueWaiting: () -> Bool
    ) async -> Bool {
        while policy == .exclusive
                && isDeliveryBlocked
                && shouldContinueWaiting() {
            await withCheckedContinuation { continuation in
                stateChangeWaiters.append(continuation)
            }
        }
        guard shouldContinueWaiting(),
              policy == .primaryPasteDuringCapture || !isDeliveryBlocked else {
            return false
        }
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

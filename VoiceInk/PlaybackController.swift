import AppKit
import Combine
import Foundation
import MediaRemoteAdapter
import SwiftUI
import os

enum RecordingMediaPauseScope: Equatable, Hashable, Sendable {
    case none
    /// Default-on protection for the internal speakers beside the microphone.
    /// This deliberately names Spotify only: the user asked VoiceInk++ to suppress
    /// Spotify bleed, not to change unrelated Music playback merely because both
    /// applications expose scriptable state.
    case spotifyOnly
    case allPublishedMedia

    var requestsPause: Bool { self != .none }
    var allowsGenericMediaRemote: Bool { self == .allPublishedMedia }
}

struct RecordingMediaPauseLease: Equatable, Hashable, Sendable {
    let id: UUID
    let scope: RecordingMediaPauseScope

    var requestsPause: Bool { scope.requestsPause }
}

struct RecordingMediaPauseBeginDecision: Equatable {
    let lease: RecordingMediaPauseLease
    let needsPauseAttempt: Bool
    let cancelsPendingResume: Bool
}

struct RecordingMediaPauseResumeRequest<Source: Equatable>: Equatable {
    let source: Source
    let generation: UInt64
}

enum RecordingMediaPauseFinishDecision<Source: Equatable>: Equatable {
    case none
    case keepPaused
    case abandon
    case resume(RecordingMediaPauseResumeRequest<Source>)
}

/// Pure ownership reducer for recording-scoped media suppression.
///
/// A paused source belongs to the set of recordings that requested suppression,
/// not to whichever asynchronous Recorder task happens to finish last. This is the
/// key rapid-recording invariant: a built-in-speaker successor inherits the owned
/// pause without an intermediate play/pause pair, while an external-output successor
/// does not cancel the previous recording's already-earned resume.
struct RecordingMediaPauseOwnership<Source: Equatable> {
    private(set) var pausedSource: Source?
    private(set) var generation: UInt64 = 0
    private var requestingLeaseIDs = Set<UUID>()

    var activePauseLeaseCount: Int {
        requestingLeaseIDs.count
    }

    mutating func beginRecording(
        scope: RecordingMediaPauseScope,
        leaseID: UUID = UUID()
    ) -> RecordingMediaPauseBeginDecision {
        let lease = RecordingMediaPauseLease(
            id: leaseID,
            scope: scope
        )
        return activateRecording(lease)
    }

    /// Activates a lease only after any canceled predecessor resume has settled.
    /// This lets a rapid successor join a command already in flight, then either
    /// inherit the still-paused source or issue one fresh pause after play finishes.
    mutating func activateRecording(
        _ lease: RecordingMediaPauseLease
    ) -> RecordingMediaPauseBeginDecision {
        guard lease.requestsPause else {
            return RecordingMediaPauseBeginDecision(
                lease: lease,
                needsPauseAttempt: false,
                cancelsPendingResume: false
            )
        }

        let inserted = requestingLeaseIDs.insert(lease.id).inserted
        guard inserted else {
            return RecordingMediaPauseBeginDecision(
                lease: lease,
                needsPauseAttempt: pausedSource == nil,
                cancelsPendingResume: false
            )
        }

        // Invalidate a delayed request even if task cancellation arrives too late.
        // The source itself remains owned and transfers to this new recording.
        generation &+= 1
        return RecordingMediaPauseBeginDecision(
            lease: lease,
            needsPauseAttempt: pausedSource == nil,
            cancelsPendingResume: true
        )
    }

    func canAttemptPause(for lease: RecordingMediaPauseLease) -> Bool {
        lease.requestsPause &&
            requestingLeaseIDs.contains(lease.id) &&
            pausedSource == nil
    }

    @discardableResult
    mutating func recordPausedSource(
        _ source: Source,
        for lease: RecordingMediaPauseLease
    ) -> Bool {
        guard canAttemptPause(for: lease) else { return false }
        pausedSource = source
        return true
    }

    /// Clears only the source named by the caller while retaining active leases.
    /// This is used after a lost Play receipt: the next recording may already have
    /// reserved the episode, but it must not inherit an unverified "still paused"
    /// assumption. The active lease can then make one fresh exact pause decision.
    @discardableResult
    mutating func clearPausedSource(ifEqual source: Source) -> Bool {
        guard pausedSource == source else { return false }
        pausedSource = nil
        generation &+= 1
        return true
    }

    mutating func finishRecording(
        _ lease: RecordingMediaPauseLease?,
        preserveCurrentPlayback: Bool
    ) -> RecordingMediaPauseFinishDecision<Source> {
        guard let lease, lease.requestsPause,
              requestingLeaseIDs.remove(lease.id) != nil else {
            return .none
        }

        guard requestingLeaseIDs.isEmpty else {
            return .keepPaused
        }

        generation &+= 1
        guard let pausedSource else { return .none }
        if preserveCurrentPlayback {
            // A playback-preserving stop can abandon only playback that this ownership
            // episode actually paused or inherited. A lease canceled before its
            // bounded Pause succeeds has no playback state to preserve and must
            // remain a no-op instead of canceling unrelated restoration work.
            self.pausedSource = nil
            return .abandon
        }

        return .resume(RecordingMediaPauseResumeRequest(
            source: pausedSource,
            generation: generation
        ))
    }

    func shouldPerformResume(
        _ request: RecordingMediaPauseResumeRequest<Source>
    ) -> Bool {
        requestingLeaseIDs.isEmpty &&
            pausedSource == request.source &&
            generation == request.generation
    }

    mutating func completeResume(
        _ request: RecordingMediaPauseResumeRequest<Source>
    ) {
        guard shouldPerformResume(request) else { return }
        // Keep the source until the explicit play operation returns. Clearing it
        // before the delay/operation is what made rapid recording lose ownership.
        pausedSource = nil
        generation &+= 1
    }
}

enum RecordingMediaPausePolicy {
    enum TransferSource: Equatable, Sendable {
        case scriptable(ScriptableMediaApp)
        case mediaRemote
    }

    static func scope(
        alwaysPauseEnabled: Bool,
        pauseOnBuiltInSpeakersEnabled: Bool,
        outputSnapshot: DefaultOutputDeviceSnapshot?
    ) -> RecordingMediaPauseScope {
        if alwaysPauseEnabled {
            return .allPublishedMedia
        }
        if pauseOnBuiltInSpeakersEnabled,
           AudioDeviceConfiguration.isMacBookBuiltInSpeakers(outputSnapshot) {
            // The default-on safety rule is deliberately narrow. Generic
            // MediaRemote is global and cannot prove it will later play the same
            // browser/tab/podcast, while Music was not part of Ethan's request.
            return .spotifyOnly
        }
        return .none
    }

    /// The built-in-speaker policy is Spotify-only. The explicit all-media policy
    /// still prefers whichever scriptable app is published as now-playing, while
    /// never letting an unrelated browser owner conceal exact Spotify/Music state.
    static func scriptableProbeOrder(
        for scope: RecordingMediaPauseScope,
        nowPlayingBundle: String?
    ) -> [ScriptableMediaApp] {
        if scope == .spotifyOnly { return [.spotify] }
        guard scope == .allPublishedMedia else { return [] }
        guard let nowPlayingBundle,
              let preferred = ScriptableMediaApp.from(bundleId: nowPlayingBundle) else {
            return ScriptableMediaApp.allCases
        }
        return [preferred] + ScriptableMediaApp.allCases.filter { $0 != preferred }
    }

    /// A narrower Spotify-only recording may inherit only playback VoiceInk++
    /// proved it paused in Spotify. Music and generic MediaRemote ownership belong
    /// exclusively to the explicit all-media scope.
    static func canTransfer(
        _ source: TransferSource,
        to scope: RecordingMediaPauseScope
    ) -> Bool {
        switch scope {
        case .none:
            return false
        case .spotifyOnly:
            return source == .scriptable(.spotify)
        case .allPublishedMedia:
            return true
        }
    }
}

// MARK: - PlaybackController
//
// Responsible for pausing active media when the recording-start policy requests
// it, and resuming only the exact source VoiceInk++ proved that it paused.
//
// Never synthesize the hardware Play/Pause key here. It is a state-blind toggle:
// stale now-playing state can make it start silence or toggle an unrelated source.
// Spotify and Music use synchronous player-state queries plus explicit AppleScript
// pause/play. Other published now-playing sources use MediaRemoteAdapter's explicit
// pause/play commands. Nothing confirmed playing means no command.
//
// Playback ownership is deliberately independent from Recorder's system-output
// unmute task. Each successful recording receives one lease. A rapid successor that
// also requires suppression transfers the owned source without a duplicate command;
// a successor on external output leaves the prior resume alone. Primary triple-click
// pause and single-click resume never touch the lease. A genuine Primary double-click releases only
// its lease with `.preserveCurrentPlayback`, issuing neither play nor pause.
@MainActor
final class PlaybackController: ObservableObject {
    static let shared = PlaybackController()

    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "PlaybackController"
    )

    // The cross-app MediaRemote bridge (perl-hosted; works on macOS 26).
    private var mediaController: MediaRemoteAdapter.MediaController
    private let scriptableMediaControl: any ScriptableMediaControlling
    private let outputSnapshotProvider: () -> DefaultOutputDeviceSnapshot?
    private let audioResumptionDelayProvider: () -> TimeInterval
    private let persistsSettings: Bool
    private var isMediaTracking = false
    private var mediaTrackingGeneration: UInt64 = 0

    // The listener is best-effort and can lag. It is used only to decide which
    // source to pause; delayed resume relies exclusively on ownedPausedMedia.
    private var isMediaPlaying = false
    private var lastKnownTrackInfo: TrackInfo?

    private struct MediaRemotePausedSource: Equatable {
        let bundleId: String
        let processIdentifier: pid_t
        let title: String
        let artist: String
        let album: String?

        /// MediaRemote itself treats a missing album on either callback as the same
        /// track. Match that contract while still requiring title, artist, PID, and
        /// bundle; otherwise a valid Pause callback can lose ownership and strand it.
        func matches(_ other: Self) -> Bool {
            guard bundleId == other.bundleId,
                  processIdentifier == other.processIdentifier,
                  title == other.title,
                  artist == other.artist else { return false }
            if let album, let otherAlbum = other.album {
                return album == otherAlbum
            }
            return true
        }
    }

    private enum PausedSource: Equatable {
        case appleScript(ScriptableMediaSource)
        case mediaRemote(MediaRemotePausedSource)

        func canTransfer(to scope: RecordingMediaPauseScope) -> Bool {
            let transferSource: RecordingMediaPausePolicy.TransferSource
            switch self {
            case .appleScript(let source):
                transferSource = .scriptable(source.app)
            case .mediaRemote:
                transferSource = .mediaRemote
            }
            return RecordingMediaPausePolicy.canTransfer(
                transferSource,
                to: scope
            )
        }
    }

    private struct PausedSourceAcquisition {
        let source: PausedSource
        let needsExactRevalidation: Bool
    }

    private var ownedPausedMedia = RecordingMediaPauseOwnership<PausedSource>()
    private struct PendingResumeOperation {
        let id: UUID
        let task: Task<Void, Never>
    }

    /// Remains published until the operation has fully returned, even after it is
    /// cancelled. Every rapid successor therefore joins the same boundary. Clearing
    /// this reference at the first successor let a third recording open AUHAL while
    /// the predecessor's already-dispatched Play was still in flight.
    private var pendingResumeOperation: PendingResumeOperation?
    /// Set only when an explicit Spotify/Music command crossed its irreversible
    /// boundary but its state receipt was lost. A successor must read exact PID,
    /// track, and state before AUHAL opens; it may never inherit this as paused.
    private var indeterminateScriptableSource: ScriptableMediaSource?
    /// A rapid recording joins the resume it canceled before activating its own
    /// lease. If play already crossed its irreversible boundary, this guarantees
    /// the successor observes completion and issues a fresh pause in-order.
    private var predecessorResumeTasks: [UUID: Task<Void, Never>] = [:]
    private struct PendingPauseOperation {
        let id: UUID
        let task: Task<Void, Never>
    }
    /// Serializes the complete predecessor-join / exact-Pause / verification path.
    /// Without this tail, two successors released by the same Play barrier could
    /// both observe `pausedSource == nil` and send duplicate Pause commands.
    private var pendingPauseOperation: PendingPauseOperation?

    /// Global override: pause active media for every output route.
    @Published var isPauseMediaEnabled: Bool {
        didSet {
            guard persistsSettings else {
                refreshMediaTracking()
                return
            }
            UserDefaults.standard.set(
                isPauseMediaEnabled,
                forKey: "isPauseMediaEnabled"
            )
            refreshMediaTracking()
        }
    }

    /// Default-on safety rule for the internal speakers beside the microphone.
    @Published var isPauseMediaOnBuiltInSpeakersEnabled: Bool {
        didSet {
            guard persistsSettings else {
                refreshMediaTracking()
                return
            }
            UserDefaults.standard.set(
                isPauseMediaOnBuiltInSpeakersEnabled,
                forKey: "isPauseMediaOnBuiltInSpeakersEnabled"
            )
            refreshMediaTracking()
        }
    }

    init(
        scriptableMediaControl: (any ScriptableMediaControlling)? = nil,
        outputSnapshotProvider: @escaping () -> DefaultOutputDeviceSnapshot? = {
            AudioDeviceConfiguration.getDefaultOutputDeviceSnapshot()
        },
        audioResumptionDelayProvider: @escaping () -> TimeInterval = {
            MediaController.shared.audioResumptionDelay
        },
        initialPauseMediaEnabled: Bool? = nil,
        initialBuiltInSpeakerPauseEnabled: Bool? = nil,
        persistsSettings: Bool = true
    ) {
        mediaController = MediaRemoteAdapter.MediaController()
        // Resolve the MainActor-isolated singleton inside the MainActor-isolated
        // initializer. Referencing it from a default-argument expression becomes
        // an error in Swift 6 because default arguments are evaluated nonisolated.
        self.scriptableMediaControl = scriptableMediaControl ?? LiveScriptableMediaControl.shared
        self.outputSnapshotProvider = outputSnapshotProvider
        self.audioResumptionDelayProvider = audioResumptionDelayProvider
        self.persistsSettings = persistsSettings
        isPauseMediaEnabled = initialPauseMediaEnabled ?? UserDefaults.standard.bool(
            forKey: "isPauseMediaEnabled"
        )
        isPauseMediaOnBuiltInSpeakersEnabled = initialBuiltInSpeakerPauseEnabled ??
            UserDefaults.standard.bool(forKey: "isPauseMediaOnBuiltInSpeakersEnabled")
        refreshMediaTracking()
    }

    // MARK: - Recording leases

    /// Freezes the media policy at recording start. Later output/setting changes
    /// cannot revoke the obligation to restore a source this lease actually paused.
    func beginRecordingPause() -> RecordingMediaPauseLease {
        let outputSnapshot = outputSnapshotProvider()
        let scope = RecordingMediaPausePolicy.scope(
            alwaysPauseEnabled: isPauseMediaEnabled,
            pauseOnBuiltInSpeakersEnabled: isPauseMediaOnBuiltInSpeakersEnabled,
            outputSnapshot: outputSnapshot
        )
        let lease = RecordingMediaPauseLease(id: UUID(), scope: scope)

        var waitsForPredecessorResume = false
        if lease.requestsPause, let predecessor = pendingResumeOperation {
            let canTransferExistingSource = ownedPausedMedia.pausedSource?
                .canTransfer(to: lease.scope) == true
            if canTransferExistingSource {
                predecessor.task.cancel()
            }
            // Keep the shared operation published until it really exits. Compatible
            // ownership cancels and transfers when Play has not crossed its boundary.
            // An incompatible broad-media source instead finishes its own Play; the
            // Spotify-only successor then makes a fresh exact Spotify decision.
            predecessorResumeTasks[lease.id] = predecessor.task
            waitsForPredecessorResume = true
        }

        if lease.requestsPause, !waitsForPredecessorResume {
            // Reserve synchronously when an earlier recording still owns the
            // paused source. Otherwise that recording could finish and schedule
            // Play before this start task gets actor time to activate its lease.
            // A predecessor Play already in flight is the sole exception: the
            // async pause path must join it before activation so it can re-pause
            // in order if Play crossed its irreversible boundary.
            if let pausedSource = ownedPausedMedia.pausedSource,
               !pausedSource.canTransfer(to: lease.scope) {
                // True overlapping incompatible recordings would require ownership
                // of two independent playback sources. The app has one capture
                // owner, so this is defensive fail-open behavior rather than silently
                // inheriting and later resuming media outside the new scope.
                logger.error("Recording media lease could not inherit an incompatible active source")
            } else {
                _ = ownedPausedMedia.activateRecording(lease)
            }
        }

        if lease.requestsPause {
            logger.info(
                "Recording media lease reserved builtInOutput=\(AudioDeviceConfiguration.isMacBookBuiltInSpeakers(outputSnapshot), privacy: .public) genericMediaRemote=\(scope.allowsGenericMediaRemote, privacy: .public)"
            )
        }
        return lease
    }

    /// Attempts one explicit pause for a lease that still owns the active episode.
    /// A transferred lease sees an existing source and therefore emits no command.
    func pauseMedia(for lease: RecordingMediaPauseLease) async {
        let predecessor = pendingPauseOperation?.task
        let operationID = UUID()
        let operation = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return }
            await self.performPauseMedia(for: lease)
        }
        pendingPauseOperation = PendingPauseOperation(
            id: operationID,
            task: operation
        )
        await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
        if pendingPauseOperation?.id == operationID {
            pendingPauseOperation = nil
        }
    }

    private func performPauseMedia(for lease: RecordingMediaPauseLease) async {
        if let predecessor = predecessorResumeTasks.removeValue(forKey: lease.id) {
            // Cancellation prevents a delayed command from starting. If play had
            // already begun, the task finishes its exact verification before this
            // lease activates, so pause/play can never overtake each other.
            await predecessor.value
        }

        // A lost Play receipt is not proof that the source stayed paused. Resolve
        // the exact PID/track before this lease decides whether a fresh Pause is
        // needed; Recorder awaits this method before AUHAL opens.
        await reconcileIndeterminateScriptableSourceBeforeCapture()

        if let incompatibleSource = ownedPausedMedia.pausedSource,
           !incompatibleSource.canTransfer(to: lease.scope),
           ownedPausedMedia.activePauseLeaseCount == 0 {
            // A narrower successor waited for the broad predecessor's Play, but
            // the explicit command could still leave that source paused. Do not
            // reinterpret Music/MediaRemote ownership as Spotify protection or
            // let it suppress the successor's exact Spotify probe. The failed
            // restoration is never retried; only its stale ownership is dropped.
            _ = ownedPausedMedia.clearPausedSource(ifEqual: incompatibleSource)
            logger.error(
                "Dropped incompatible playback ownership after predecessor resume settled"
            )
        }

        let decision = ownedPausedMedia.activateRecording(lease)
        guard decision.needsPauseAttempt,
              !Task.isCancelled,
              ownedPausedMedia.canAttemptPause(for: lease) else { return }

        guard let acquisition = await pauseActiveSourceIfPlaying(
            scope: lease.scope
        ) else {
            logger.info("No active media detected on record start; nothing paused")
            return
        }

        guard ownedPausedMedia.recordPausedSource(acquisition.source, for: lease) else {
            // The lease is revalidated after every bounded async transport. If it
            // stopped owning the episode while that command was in flight, fail
            // closed rather than guessing with another playback command.
            logger.error("Paused media source could not be attached to its recording lease")
            return
        }
        if acquisition.needsExactRevalidation,
           case .appleScript(let source) = acquisition.source {
            // `pauseIfPlaying` already performed the one bounded read-only recovery
            // check before returning. Retain an unresolved result only as a marker
            // for stop/next-recording reconciliation; do not stack another startup
            // delay in front of AUHAL.
            indeterminateScriptableSource = source
        }
    }

    /// Ends exactly one recording lease. Normal completion schedules one owned
    /// resume; an explicit playback-preserving stop abandons ownership without playback.
    func finishRecordingPause(
        _ lease: RecordingMediaPauseLease?,
        playbackDisposition: RecordingStopPlaybackDisposition
    ) {
        let decision = ownedPausedMedia.finishRecording(
            lease,
            preserveCurrentPlayback: playbackDisposition == .preserveCurrentPlayback
        )

        switch decision {
        case .none:
            refreshMediaTracking()
        case .keepPaused:
            logger.info("Recording media lease ended; a newer recording retains the paused source")
        case .abandon:
            pendingResumeOperation?.task.cancel()
            pendingResumeOperation = nil
            indeterminateScriptableSource = nil
            logger.info("Abandoned recording media ownership without play/pause")
            refreshMediaTracking()
        case .resume(let request):
            scheduleResume(request)
        }
    }

    // MARK: - Explicit transport operations

    private func pauseActiveSourceIfPlaying(
        scope: RecordingMediaPauseScope
    ) async -> PausedSourceAcquisition? {
        let nowPlayingBundle = lastKnownTrackInfo?.payload.bundleIdentifier
        let listenerSaysPlaying = isMediaPlaying &&
            lastKnownTrackInfo?.payload.isPlaying == true

        // The built-in-speaker path probes Spotify only. The older explicit
        // all-media setting retains Spotify/Music plus MediaRemote behavior. One
        // deadline covers every exact read and command so an unavailable player
        // cannot make the recording trigger appear dead.
        let startupDeadline = scriptableMediaControl.makeStartupDeadline()
        for app in RecordingMediaPausePolicy.scriptableProbeOrder(
            for: scope,
            nowPlayingBundle: nowPlayingBundle
        ) where scriptableMediaControl.isRunning(app) {
            switch await scriptableMediaControl.pauseIfPlaying(
                app,
                deadline: startupDeadline
            ) {
            case .paused(let source):
                logger.info("Paused \(app.rawValue, privacy: .public) with verified exact state")
                return PausedSourceAcquisition(
                    source: .appleScript(source),
                    needsExactRevalidation: false
                )
            case .indeterminate(let source):
                logger.error("Pause state for \(app.rawValue, privacy: .public) is indeterminate")
                return PausedSourceAcquisition(
                    source: .appleScript(source),
                    needsExactRevalidation: true
                )
            case .notPlaying:
                continue
            }
        }

        // The default-on built-in-speaker rule deliberately stops here. Only the
        // older explicit "Pause Media While Recording" setting opts into this
        // global transport, because MediaRemote cannot address a particular tab.
        guard scope.allowsGenericMediaRemote,
              listenerSaysPlaying,
              let trackInfo = lastKnownTrackInfo,
              let source = mediaRemoteSource(from: trackInfo) else {
            return nil
        }
        // Preserve the existing explicit all-media setting's transport semantics.
        // The adapter exposes only a fire-and-forget command, not an awaited receipt;
        // ownership therefore begins at dispatch just as it did before this feature.
        // The default MacBook-speaker rule never enters this generic path.
        mediaController.pause()
        logger.info(
            "Dispatched explicit MediaRemote Pause for \(source.bundleId, privacy: .public)"
        )
        return PausedSourceAcquisition(
            source: .mediaRemote(source),
            needsExactRevalidation: false
        )
    }

    /// Reconciles a lost Spotify/Music command receipt without issuing a playback
    /// command. Confirmed paused state becomes transferable; every other readable
    /// state clears the inherited source so this recording can make a fresh Pause.
    /// Unreadable state also clears the assumption and fails open for dictation.
    private func reconcileIndeterminateScriptableSourceBeforeCapture() async {
        guard let source = indeterminateScriptableSource else { return }
        let ownedSource = PausedSource.appleScript(source)
        switch await scriptableMediaControl.observation(for: source.app) {
        case .paused(let current) where current == source:
            indeterminateScriptableSource = nil
            logger.info("Revalidated exact scriptable source as paused before capture")
        case .playing, .paused, .stopped, .notRunning, .unavailable:
            _ = ownedPausedMedia.clearPausedSource(ifEqual: ownedSource)
            indeterminateScriptableSource = nil
            logger.info("Cleared indeterminate scriptable ownership before fresh pause decision")
        }
    }

    private func scheduleResume(
        _ request: RecordingMediaPauseResumeRequest<PausedSource>
    ) {
        pendingResumeOperation?.task.cancel()
        let delay = audioResumptionDelayProvider()
        let operationID = UUID()
        let task = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            }
            guard let self else { return }
            guard !Task.isCancelled else {
                self.finishPendingResumeOperation(operationID)
                return
            }
            await self.performResume(request, operationID: operationID)
        }
        pendingResumeOperation = PendingResumeOperation(
            id: operationID,
            task: task
        )
    }

    private func performResume(
        _ request: RecordingMediaPauseResumeRequest<PausedSource>,
        operationID: UUID
    ) async {
        defer {
            finishPendingResumeOperation(operationID)
        }
        guard ownedPausedMedia.shouldPerformResume(request) else {
            logger.info("Ignored stale recording media resume request")
            return
        }

        let resolvedOwnership: Bool
        switch request.source {
        case .appleScript(let source):
            switch await scriptableMediaControl.playIfPaused(source) {
            case .played:
                indeterminateScriptableSource = nil
                resolvedOwnership = true
                logger.info(
                    "Resumed \(source.app.rawValue, privacy: .public) with verified PID/track state"
                )
            case .noLongerPaused:
                // The exact process, track, or playback state changed after the
                // pause. Respect that newer state and never Play by app name alone.
                indeterminateScriptableSource = nil
                resolvedOwnership = true
                logger.info(
                    "Did not resume \(source.app.rawValue, privacy: .public) because the exact paused source changed"
                )
            case .stillPaused:
                indeterminateScriptableSource = nil
                resolvedOwnership = false
                logger.error(
                    "Explicit Play left \(source.app.rawValue, privacy: .public) paused; retaining exact ownership"
                )
            case .indeterminate:
                // Do not equate a lost receipt with "still paused". Retain the
                // source only as a recovery candidate so the next built-in-speaker
                // recording must re-read exact state before opening AUHAL.
                indeterminateScriptableSource = source
                resolvedOwnership = false
                logger.error(
                    "Playback restoration for \(source.app.rawValue, privacy: .public) is indeterminate"
                )
            }
        case let .mediaRemote(source):
            if isExactMediaRemoteSourceCurrent(source, isPlaying: false) {
                // The legacy generic adapter exposes no command receipt. Preserve
                // its established explicit-Play behavior and clear ownership at
                // dispatch; otherwise a listener timeout can poison the next WAV.
                mediaController.play()
                resolvedOwnership = true
                logger.info(
                    "Dispatched explicit MediaRemote Play for exact source in \(source.bundleId, privacy: .public)"
                )
            } else {
                logger.info(
                    "Resume skipped: exact MediaRemote source is no longer current"
                )
                // The user changed the global now-playing source. Abandon the old
                // source rather than issuing Play to an unrelated app/tab.
                resolvedOwnership = true
            }
        }

        if resolvedOwnership {
            ownedPausedMedia.completeResume(request)
        }
    }

    private func finishPendingResumeOperation(_ operationID: UUID) {
        if pendingResumeOperation?.id == operationID {
            pendingResumeOperation = nil
        }
        refreshMediaTracking()
    }

    private func mediaRemoteSource(
        from trackInfo: TrackInfo
    ) -> MediaRemotePausedSource? {
        let payload = trackInfo.payload
        guard let bundleId = payload.bundleIdentifier,
              let processIdentifier = payload.PID else { return nil }
        guard let title = normalizedMediaRemoteField(payload.title),
              let artist = normalizedMediaRemoteField(payload.artist) else {
            return nil
        }
        return MediaRemotePausedSource(
            bundleId: bundleId,
            processIdentifier: processIdentifier,
            title: title,
            artist: artist,
            album: normalizedMediaRemoteField(payload.album)
        )
    }

    private func normalizedMediaRemoteField(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !normalized.isEmpty else { return nil }
        return normalized
    }

    private func isExactMediaRemoteSourceCurrent(
        _ source: MediaRemotePausedSource,
        isPlaying: Bool
    ) -> Bool {
        guard let current = lastKnownTrackInfo,
              current.payload.isPlaying == isPlaying,
              let currentSource = mediaRemoteSource(from: current) else { return false }
        return source.matches(currentSource)
    }

    // MARK: - MediaRemote tracking

    private func setupMediaControllerCallbacks(
        for controller: MediaRemoteAdapter.MediaController,
        generation: UInt64
    ) {
        controller.onTrackInfoReceived = { [weak self, weak controller] trackInfo in
            Task { @MainActor [weak self, weak controller] in
                guard let self, let controller,
                      self.mediaTrackingGeneration == generation,
                      self.mediaController === controller,
                      self.isMediaTracking else { return }
                self.isMediaPlaying = trackInfo?.payload.isPlaying ?? false
                self.lastKnownTrackInfo = trackInfo
            }
        }
        // The adapter owns its listener restart policy. Do not wrap termination in
        // another restart loop: old process callbacks can race a replacement and
        // create duplicate/unowned helpers. This is unrelated to the exact
        // Spotify built-in-speaker feature, which needs no listener at all.
        controller.onListenerTerminated = { }
    }

    private func refreshMediaTracking() {
        // The default-on MacBook-speaker rule probes only exact scriptable apps
        // and therefore needs no persistent MediaRemote helper. Keep the helper
        // alive only for the user's explicit all-media setting.
        if isPauseMediaEnabled {
            startMediaTracking()
        } else {
            stopMediaTracking()
        }
    }

    private func startMediaTracking() {
        guard !isMediaTracking else { return }
        mediaTrackingGeneration &+= 1
        let controller = MediaRemoteAdapter.MediaController()
        mediaController = controller
        setupMediaControllerCallbacks(
            for: controller,
            generation: mediaTrackingGeneration
        )
        isMediaTracking = true
        controller.startListening()
    }

    private func stopMediaTracking() {
        guard isMediaTracking else { return }
        // A recording freezes its pause policy at start. If the all-media setting
        // is switched off mid-recording, retain the listener/snapshot until that
        // owned episode either resumes or is explicitly abandoned.
        if ownedPausedMedia.activePauseLeaseCount > 0 ||
            ownsMediaRemoteSource || pendingResumeOperation != nil {
            return
        }
        mediaTrackingGeneration &+= 1
        isMediaTracking = false
        let controller = mediaController
        controller.onTrackInfoReceived = nil
        controller.onListenerTerminated = nil
        controller.stopListening()
        isMediaPlaying = false
        lastKnownTrackInfo = nil
        mediaController = MediaRemoteAdapter.MediaController()
    }

    private var ownsMediaRemoteSource: Bool {
        guard case .mediaRemote = ownedPausedMedia.pausedSource else { return false }
        return true
    }

    deinit {
        pendingResumeOperation?.task.cancel()
        pendingPauseOperation?.task.cancel()
        predecessorResumeTasks.values.forEach { $0.cancel() }
        mediaController.onTrackInfoReceived = nil
        mediaController.onListenerTerminated = nil
        mediaController.stopListening()
    }
}

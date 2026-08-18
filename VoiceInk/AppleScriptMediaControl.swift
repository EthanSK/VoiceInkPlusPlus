import AppKit
import Foundation
import os

// MARK: - Scriptable media identity

enum ScriptableMediaApp: String, CaseIterable, Sendable {
    case spotify = "Spotify"
    case appleMusic = "Music"

    static func from(bundleId: String) -> ScriptableMediaApp? {
        switch bundleId {
        case "com.spotify.client": return .spotify
        case "com.apple.Music": return .appleMusic
        default: return nil
        }
    }

    var bundleId: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .appleMusic: return "com.apple.Music"
        }
    }

    fileprivate var trackIdentifierProperty: AEKeyword {
        switch self {
        case .spotify: return AEKeyword(0x4944_2020) // 'ID  '
        case .appleMusic: return AEKeyword(0x7050_4953) // 'pPIS'
        }
    }

    fileprivate var commandEventClass: AEEventClass {
        switch self {
        case .spotify: return AEEventClass(0x7370_6679) // 'spfy'
        case .appleMusic: return AEEventClass(0x686F_6F6B) // 'hook'
        }
    }
}

/// The exact already-running process that one media transaction may address.
/// A process ID alone can eventually be reused, so every event revalidates the
/// bundle identifier and executable URL captured at the decision boundary.
struct ScriptableMediaTarget: Equatable, Sendable {
    let app: ScriptableMediaApp
    let processIdentifier: pid_t
    let executableURL: URL
}

/// Exact in-memory identity for playback VoiceInk++ may later restore.
///
/// Bundle identity alone is insufficient: Spotify/Music can quit and relaunch, or
/// the user can choose another paused track while dictation is active. PID plus the
/// provider's stable track ID is revalidated before every Play. Track identifiers
/// never enter logs, persisted settings, process arguments, or environment values.
struct ScriptableMediaSource: Equatable, Hashable, Sendable {
    let app: ScriptableMediaApp
    let processIdentifier: pid_t
    let trackIdentifier: String
}

enum ScriptableMediaIdentityPolicy {
    static func isSafeTrackIdentifier(
        _ value: String,
        for app: ScriptableMediaApp
    ) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }

        switch app {
        case .spotify:
            guard value.hasPrefix("spotify:") else { return false }
            let allowed = CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: ":%._-")
            )
            return value.unicodeScalars.allSatisfy(allowed.contains)
        case .appleMusic:
            guard value.utf8.count <= 64 else { return false }
            return value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
            }
        }
    }
}

enum ScriptableMediaPlaybackObservation: Equatable, Sendable {
    case playing(ScriptableMediaSource)
    case paused(ScriptableMediaSource)
    case stopped
    case notRunning
    case unavailable
}

enum ScriptableMediaPauseResult: Equatable, Sendable {
    case paused(ScriptableMediaSource)
    case notPlaying
    /// Pause crossed its irreversible boundary, but the single bounded transaction
    /// could not read a conclusive post-state. The source is only a recovery
    /// candidate and must be re-read before later code assumes it stayed paused.
    case indeterminate(ScriptableMediaSource)
}

enum ScriptableMediaPlayResult: Equatable, Sendable {
    case played
    case stillPaused
    case noLongerPaused
    /// Play crossed its irreversible boundary but its exact post-state was unreadable.
    case indeterminate
}

enum ScriptableMediaFixedCommand: Equatable, Sendable {
    case pause
    case play

    fileprivate var eventID: AEEventID {
        switch self {
        case .pause: return AEEventID(0x5061_7573) // 'Paus'
        case .play: return AEEventID(0x506C_6179) // 'Play'
        }
    }
}

enum ScriptableMediaCommandNotSentReason: Equatable, Sendable {
    case cancelledBeforeDispatch
    case deadlineExpired
    case sourceChangedBeforeDispatch
    case targetChangedBeforeDispatch
    case unreadableBeforeDispatch
}

enum ScriptableMediaCommandDispatch: Equatable, Sendable {
    /// No command Apple Event was sent, so no playback mutation can arrive later.
    case notSent(ScriptableMediaCommandNotSentReason)
    /// The PID-addressed event crossed the send boundary. A missing reply remains
    /// indeterminate because the target may still have applied the command.
    case crossedIrreversibleBoundary
}

/// Lock-backed because cancellation may arrive on a different executor while the
/// transport's serial queue is between its final state read and command dispatch.
final class MediaCommandCancellation: @unchecked Sendable {
    private enum State: Equatable {
        case pending
        case cancelled
        case dispatchClaimed
    }

    private let lock = NSLock()
    private var state: State = .pending

    func cancel() {
        lock.lock()
        if state == .pending {
            state = .cancelled
        }
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .cancelled
    }

    /// Atomically resolves the last cancellation-versus-command race. Once this
    /// returns true, later cancellation is post-dispatch for ownership purposes;
    /// callers must immediately enter the irreversible send and then reconcile it.
    func claimDispatch() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .pending else { return false }
        state = .dispatchClaimed
        return true
    }
}

/// Injectable boundary used by the live PID-addressed transport and deterministic
/// race tests. Implementations must never launch or activate a media application.
protocol ScriptableMediaTransport: Sendable {
    func observe(
        _ target: ScriptableMediaTarget,
        deadline: ContinuousClock.Instant
    ) async -> ScriptableMediaPlaybackObservation

    func sendIfCurrent(
        _ command: ScriptableMediaFixedCommand,
        source: ScriptableMediaSource,
        target: ScriptableMediaTarget,
        deadline: ContinuousClock.Instant,
        cancellation: MediaCommandCancellation
    ) async -> ScriptableMediaCommandDispatch
}

// MARK: - PID-addressed Apple Event transport

/// Sends the same explicit Spotify/Music commands as AppleScript, but addresses
/// every read and command to the captured process identifier. A name- or
/// bundle-addressed script can silently mutate a replacement process if the app
/// relaunches between validation and command dispatch; a PID target cannot.
///
/// Blocking Apple Event calls run on one private serial queue. Every call receives
/// the recording transaction's shared deadline, uses `NeverInteract`, and caps one
/// individual event so a nonresponsive app cannot make the recording shortcut look
/// dead. The cancellation token is checked on this same queue immediately before
/// `sendEvent`, closing the observation-to-dispatch race left by Task cancellation.
final class PIDAddressedMediaAppleEventTransport: ScriptableMediaTransport, @unchecked Sendable {
    static let shared = PIDAddressedMediaAppleEventTransport()

    private static let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "PIDMediaAppleEvent"
    )
    private static let maximumEventTimeout: TimeInterval = 0.15
    private static let postCommandReserve: TimeInterval = 0.30
    private static let playerStateProperty = AEKeyword(0x7050_6C53) // 'pPlS'
    private static let currentTrackProperty = AEKeyword(0x7054_726B) // 'pTrk'
    private static let playingState = OSType(0x6B50_5350) // 'kPSP'
    private static let pausedState = OSType(0x6B50_5370) // 'kPSp'
    private static let stoppedState = OSType(0x6B50_5353) // 'kPSS'

    private let queue = DispatchQueue(
        label: "com.ethansk.voiceink.pid-media-apple-events",
        qos: .userInitiated
    )

    func observe(
        _ target: ScriptableMediaTarget,
        deadline: ContinuousClock.Instant
    ) async -> ScriptableMediaPlaybackObservation {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.observeSynchronously(
                    target,
                    deadline: deadline
                ))
            }
        }
    }

    func sendIfCurrent(
        _ command: ScriptableMediaFixedCommand,
        source: ScriptableMediaSource,
        target: ScriptableMediaTarget,
        deadline: ContinuousClock.Instant,
        cancellation: MediaCommandCancellation
    ) async -> ScriptableMediaCommandDispatch {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.sendSynchronouslyIfCurrent(
                    command,
                    source: source,
                    target: target,
                    deadline: deadline,
                    cancellation: cancellation
                ))
            }
        }
    }

    private static func observeSynchronously(
        _ target: ScriptableMediaTarget,
        deadline: ContinuousClock.Instant
    ) -> ScriptableMediaPlaybackObservation {
        guard targetIsCurrent(target) else { return .notRunning }
        do {
            let stateSpecifier = try propertySpecifier(playerStateProperty)
            let stateDescriptor = try get(
                stateSpecifier,
                target: target,
                deadline: deadline
            )
            let state = stateDescriptor.enumCodeValue
            if state == stoppedState { return .stopped }
            guard state == playingState || state == pausedState else {
                return .unavailable
            }

            let currentTrackSpecifier = try propertySpecifier(currentTrackProperty)
            let identifierSpecifier = try propertySpecifier(
                target.app.trackIdentifierProperty,
                container: currentTrackSpecifier
            )
            let identifierDescriptor = try get(
                identifierSpecifier,
                target: target,
                deadline: deadline
            )
            guard let identifier = identifierDescriptor.stringValue,
                  ScriptableMediaIdentityPolicy.isSafeTrackIdentifier(
                    identifier,
                    for: target.app
                  ) else {
                return .unavailable
            }

            let source = ScriptableMediaSource(
                app: target.app,
                processIdentifier: target.processIdentifier,
                trackIdentifier: identifier
            )
            return state == playingState ? .playing(source) : .paused(source)
        } catch {
            log(error, operation: "read", app: target.app)
            return .unavailable
        }
    }

    private static func sendSynchronouslyIfCurrent(
        _ command: ScriptableMediaFixedCommand,
        source: ScriptableMediaSource,
        target: ScriptableMediaTarget,
        deadline: ContinuousClock.Instant,
        cancellation: MediaCommandCancellation
    ) -> ScriptableMediaCommandDispatch {
        guard targetIsCurrent(target),
              source.app == target.app,
              source.processIdentifier == target.processIdentifier else {
            return .notSent(.targetChangedBeforeDispatch)
        }

        let expectedState: ScriptableMediaPlaybackObservation = command == .pause
            ? .playing(source)
            : .paused(source)
        let current = observeSynchronously(target, deadline: deadline)
        guard current == expectedState else {
            switch current {
            case .playing, .paused, .stopped:
                return .notSent(.sourceChangedBeforeDispatch)
            case .notRunning:
                return .notSent(.targetChangedBeforeDispatch)
            case .unavailable:
                return .notSent(.unreadableBeforeDispatch)
            }
        }

        guard timeoutRemaining(
            until: deadline,
            reserving: postCommandReserve
        ) != nil else {
            return .notSent(.deadlineExpired)
        }
        guard targetIsCurrent(target) else {
            return .notSent(.targetChangedBeforeDispatch)
        }

        guard let timeout = timeoutRemaining(
            until: deadline,
            reserving: postCommandReserve
        ) else {
            return .notSent(.deadlineExpired)
        }
        let targetDescriptor = NSAppleEventDescriptor(
            processIdentifier: target.processIdentifier
        )
        let event = NSAppleEventDescriptor(
            eventClass: target.app.commandEventClass,
            eventID: command.eventID,
            targetDescriptor: targetDescriptor,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        // Construct and validate first, then atomically claim the command at the
        // last possible boundary. A stop that wins this lock sends nothing; a stop
        // after the claim must let the one explicit command finish verification.
        guard cancellation.claimDispatch() else {
            return .notSent(.cancelledBeforeDispatch)
        }
        do {
            _ = try event.sendEvent(
                options: [.waitForReply, .neverInteract, .dontRecord],
                timeout: timeout
            )
        } catch {
            // Calling send is the irreversible boundary. A timeout or lost reply
            // cannot prove the exact PID ignored the explicit command, so recovery
            // must read state and must never retry the command.
            log(error, operation: command == .pause ? "pause" : "play", app: target.app)
        }
        return .crossedIrreversibleBoundary
    }

    private static func get(
        _ objectSpecifier: NSAppleEventDescriptor,
        target: ScriptableMediaTarget,
        deadline: ContinuousClock.Instant
    ) throws -> NSAppleEventDescriptor {
        guard targetIsCurrent(target) else {
            throw MediaAppleEventError.targetChanged
        }
        guard let timeout = timeoutRemaining(until: deadline) else {
            throw MediaAppleEventError.deadlineExpired
        }
        let targetDescriptor = NSAppleEventDescriptor(
            processIdentifier: target.processIdentifier
        )
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kAECoreSuite),
            eventID: AEEventID(kAEGetData),
            targetDescriptor: targetDescriptor,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            objectSpecifier,
            forKeyword: AEKeyword(keyDirectObject)
        )
        let reply = try event.sendEvent(
            options: [.waitForReply, .neverInteract, .dontRecord],
            timeout: timeout
        )
        guard let result = reply.paramDescriptor(
            forKeyword: AEKeyword(keyAEResult)
        ) else {
            throw MediaAppleEventError.missingResult
        }
        return result
    }

    private static func propertySpecifier(
        _ propertyCode: AEKeyword,
        container: NSAppleEventDescriptor? = nil
    ) throws -> NSAppleEventDescriptor {
        var containerDescription = AEDesc()
        let containerStatus: OSErr
        if let pointer = container?.aeDesc {
            containerStatus = AEDuplicateDesc(pointer, &containerDescription)
        } else {
            containerStatus = AECreateDesc(
                DescType(typeNull),
                nil,
                0,
                &containerDescription
            )
        }
        guard containerStatus == 0 else {
            throw MediaAppleEventError.osStatus(containerStatus)
        }
        defer { AEDisposeDesc(&containerDescription) }

        var property = propertyCode
        var keyData = AEDesc()
        let keyStatus = AECreateDesc(
            DescType(typeType),
            &property,
            MemoryLayout<AEKeyword>.size,
            &keyData
        )
        guard keyStatus == 0 else {
            throw MediaAppleEventError.osStatus(keyStatus)
        }
        defer { AEDisposeDesc(&keyData) }

        var objectSpecifier = AEDesc()
        let objectStatus = CreateObjSpecifier(
            DescType(typeProperty),
            &containerDescription,
            DescType(formPropertyID),
            &keyData,
            false,
            &objectSpecifier
        )
        guard objectStatus == 0 else {
            throw MediaAppleEventError.osStatus(objectStatus)
        }
        return NSAppleEventDescriptor(aeDescNoCopy: &objectSpecifier)
    }

    private static func targetIsCurrent(
        _ target: ScriptableMediaTarget
    ) -> Bool {
        guard let running = NSRunningApplication(
            processIdentifier: target.processIdentifier
        ), !running.isTerminated,
        running.bundleIdentifier == target.app.bundleId,
        let executableURL = running.executableURL else { return false }
        return executableURL.standardizedFileURL ==
            target.executableURL.standardizedFileURL
    }

    private static func timeoutRemaining(
        until deadline: ContinuousClock.Instant,
        reserving reserve: TimeInterval = 0
    ) -> TimeInterval? {
        let components = ContinuousClock.now.duration(to: deadline).components
        let remaining = Double(components.seconds) +
            Double(components.attoseconds) / 1_000_000_000_000_000_000 - reserve
        guard remaining > 0 else { return nil }
        return min(maximumEventTimeout, remaining)
    }

    private static func log(
        _ error: Error,
        operation: String,
        app: ScriptableMediaApp
    ) {
        // Never log source identity, event descriptors, or target application data.
        logger.error(
            "PID-addressed \(app.rawValue, privacy: .public) media \(operation, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
        )
    }

    private enum MediaAppleEventError: LocalizedError {
        case deadlineExpired
        case missingResult
        case osStatus(OSErr)
        case targetChanged

        var errorDescription: String? {
            switch self {
            case .deadlineExpired: return "operation deadline expired"
            case .missingResult: return "Apple Event reply had no result"
            case .osStatus(let status): return "Apple Event status \(status)"
            case .targetChanged: return "target process changed"
            }
        }
    }
}

// MARK: - Bounded transaction coordinator

/// Coordinates exact reads and one explicit command. The transport is injectable so
/// cancellation, source-change, lost-receipt, and ordering races are executable unit
/// tests instead of source-text assertions.
@MainActor
final class PIDAddressedScriptableMediaController {
    typealias TargetResolver = (ScriptableMediaApp) -> ScriptableMediaTarget?

    private let transport: any ScriptableMediaTransport
    private let targetResolver: TargetResolver

    init(
        transport: any ScriptableMediaTransport,
        targetResolver: @escaping TargetResolver
    ) {
        self.transport = transport
        self.targetResolver = targetResolver
    }

    func isRunning(_ app: ScriptableMediaApp) -> Bool {
        targetResolver(app) != nil
    }

    func observation(
        for app: ScriptableMediaApp,
        deadline: ContinuousClock.Instant
    ) async -> ScriptableMediaPlaybackObservation {
        guard let target = targetResolver(app) else { return .notRunning }
        let observation = await transport.observe(target, deadline: deadline)
        guard targetResolver(app) == target else { return .notRunning }
        return observation
    }

    /// If the source changes before Pause, `sendIfCurrent` returns without sending
    /// and the controller makes one bounded fresh decision. A second change fails
    /// open. Once a command crosses its boundary, post-state is always reconciled
    /// and an indeterminate command is never retried.
    func pauseIfPlaying(
        _ app: ScriptableMediaApp,
        deadline: ContinuousClock.Instant,
        cancellation: MediaCommandCancellation
    ) async -> ScriptableMediaPauseResult {
        guard let target = targetResolver(app),
              case .playing(var candidate) = await transport.observe(
                target,
                deadline: deadline
              ),
              targetResolver(app) == target else {
            return .notPlaying
        }

        for attempt in 0..<2 {
            let dispatch = await transport.sendIfCurrent(
                .pause,
                source: candidate,
                target: target,
                deadline: deadline,
                cancellation: cancellation
            )
            switch dispatch {
            case .notSent(.sourceChangedBeforeDispatch) where attempt == 0:
                guard case .playing(let replacement) = await transport.observe(
                    target,
                    deadline: deadline
                ), targetResolver(app) == target else {
                    return .notPlaying
                }
                candidate = replacement
                continue
            case .notSent:
                return .notPlaying
            case .crossedIrreversibleBoundary:
                let postCommand = await transport.observe(target, deadline: deadline)
                guard targetResolver(app) == target else {
                    return .indeterminate(candidate)
                }
                switch postCommand {
                case .paused(let source) where source == candidate:
                    return .paused(candidate)
                case .paused(let current):
                    // Spotify can advance between the final exact read and the
                    // app-level Pause command. The verified post-state is then the
                    // only source VoiceInk++ may safely restore. Keep it explicitly
                    // indeterminate rather than stranding the newly paused track or
                    // pretending causation was proved.
                    return .indeterminate(current)
                case .unavailable:
                    return .indeterminate(candidate)
                case .playing, .stopped, .notRunning:
                    return .notPlaying
                }
            }
        }
        return .notPlaying
    }

    func playIfPaused(
        _ source: ScriptableMediaSource,
        deadline: ContinuousClock.Instant,
        cancellation: MediaCommandCancellation
    ) async -> ScriptableMediaPlayResult {
        guard let target = targetResolver(source.app),
              target.processIdentifier == source.processIdentifier else {
            return .noLongerPaused
        }

        let dispatch = await transport.sendIfCurrent(
            .play,
            source: source,
            target: target,
            deadline: deadline,
            cancellation: cancellation
        )
        switch dispatch {
        case .notSent(.cancelledBeforeDispatch):
            return .stillPaused
        case .notSent(.deadlineExpired), .notSent(.unreadableBeforeDispatch):
            return .stillPaused
        case .notSent(.sourceChangedBeforeDispatch),
                .notSent(.targetChangedBeforeDispatch):
            return .noLongerPaused
        case .crossedIrreversibleBoundary:
            let postCommand = await transport.observe(target, deadline: deadline)
            guard targetResolver(source.app) == target else {
                return .noLongerPaused
            }
            switch postCommand {
            case .playing(let current) where current == source:
                return .played
            case .paused(let current) where current == source:
                return .stillPaused
            case .unavailable:
                return .indeterminate
            case .playing, .paused, .stopped, .notRunning:
                return .noLongerPaused
            }
        }
    }
}

// MARK: - Live facade

/// PlaybackController depends on this narrow boundary so rapid-recording ordering
/// can be exercised with a deterministic fake instead of source-text assertions.
/// The live implementation below never launches, activates, or focuses a player.
@MainActor
protocol ScriptableMediaControlling: AnyObject {
    func makeStartupDeadline() -> ContinuousClock.Instant
    func isRunning(_ app: ScriptableMediaApp) -> Bool
    func pauseIfPlaying(
        _ app: ScriptableMediaApp,
        deadline: ContinuousClock.Instant
    ) async -> ScriptableMediaPauseResult
    func playIfPaused(
        _ source: ScriptableMediaSource
    ) async -> ScriptableMediaPlayResult
    func observation(
        for app: ScriptableMediaApp
    ) async -> ScriptableMediaPlaybackObservation
}

/// Historical call-site name retained to keep this change narrow. The implementation
/// no longer runs AppleScript text or addresses applications by name: it uses fixed
/// PID-targeted Apple Events and one shared deadline per recording-start transaction.
@MainActor
enum AppleScriptMediaControl {
    private static let startupBudget = Duration.milliseconds(800)
    private static let resumeBudget = Duration.milliseconds(800)
    private static let observationBudget = Duration.milliseconds(300)
    private static let controller = PIDAddressedScriptableMediaController(
        transport: PIDAddressedMediaAppleEventTransport.shared,
        targetResolver: runningTarget(for:)
    )

    static func makeStartupDeadline() -> ContinuousClock.Instant {
        ContinuousClock.now.advanced(by: startupBudget)
    }

    static func isRunning(_ app: ScriptableMediaApp) -> Bool {
        controller.isRunning(app)
    }

    static func pauseIfPlaying(
        _ app: ScriptableMediaApp,
        deadline: ContinuousClock.Instant
    ) async -> ScriptableMediaPauseResult {
        let cancellation = MediaCommandCancellation()
        return await withTaskCancellationHandler {
            await controller.pauseIfPlaying(
                app,
                deadline: deadline,
                cancellation: cancellation
            )
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func playIfPaused(
        _ source: ScriptableMediaSource
    ) async -> ScriptableMediaPlayResult {
        let cancellation = MediaCommandCancellation()
        return await withTaskCancellationHandler {
            await controller.playIfPaused(
                source,
                deadline: ContinuousClock.now.advanced(by: resumeBudget),
                cancellation: cancellation
            )
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func observation(
        for app: ScriptableMediaApp,
        deadline: ContinuousClock.Instant? = nil
    ) async -> ScriptableMediaPlaybackObservation {
        await controller.observation(
            for: app,
            deadline: deadline ?? ContinuousClock.now.advanced(by: observationBudget)
        )
    }

    private static func runningTarget(
        for app: ScriptableMediaApp
    ) -> ScriptableMediaTarget? {
        let matches = NSRunningApplication.runningApplications(
            withBundleIdentifier: app.bundleId
        ).filter { !$0.isTerminated }
        guard matches.count == 1,
              let executableURL = matches[0].executableURL else { return nil }
        return ScriptableMediaTarget(
            app: app,
            processIdentifier: matches[0].processIdentifier,
            executableURL: executableURL.standardizedFileURL
        )
    }
}

/// Object-shaped adapter for the static live facade. Keeping it separate makes the
/// production call sites explicit while allowing tests to control command ordering.
@MainActor
final class LiveScriptableMediaControl: ScriptableMediaControlling {
    static let shared = LiveScriptableMediaControl()

    private init() {}

    func makeStartupDeadline() -> ContinuousClock.Instant {
        AppleScriptMediaControl.makeStartupDeadline()
    }

    func isRunning(_ app: ScriptableMediaApp) -> Bool {
        AppleScriptMediaControl.isRunning(app)
    }

    func pauseIfPlaying(
        _ app: ScriptableMediaApp,
        deadline: ContinuousClock.Instant
    ) async -> ScriptableMediaPauseResult {
        await AppleScriptMediaControl.pauseIfPlaying(app, deadline: deadline)
    }

    func playIfPaused(
        _ source: ScriptableMediaSource
    ) async -> ScriptableMediaPlayResult {
        await AppleScriptMediaControl.playIfPaused(source)
    }

    func observation(
        for app: ScriptableMediaApp
    ) async -> ScriptableMediaPlaybackObservation {
        await AppleScriptMediaControl.observation(for: app)
    }
}

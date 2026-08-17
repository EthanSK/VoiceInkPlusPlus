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

    fileprivate var currentTrackIdentifierExpression: String {
        switch self {
        case .spotify: return "id of current track as text"
        case .appleMusic: return "persistent ID of current track as text"
        }
    }
}

/// Exact in-memory identity for playback VoiceInk++ may later restore.
///
/// Bundle identity alone is insufficient: Spotify/Music can quit and relaunch, or
/// the user can choose another paused track while dictation is active. PID plus the
/// provider's stable track ID is revalidated before every Play. A strictly
/// whitelisted ID may enter the fixed stdin-only AppleScript comparison, but never
/// logs, persisted settings, argv, or environment values.
struct ScriptableMediaSource: Equatable, Hashable, Sendable {
    let app: ScriptableMediaApp
    let processIdentifier: pid_t
    let trackIdentifier: String
}

/// Allows the real stable identifiers returned by Spotify and Music while keeping
/// the later AppleScript string literal non-injectable. Spotify returns URI-shaped
/// values such as `spotify:track:<base62>` (and can return episode/local variants),
/// whereas Music returns a hexadecimal persistent ID. Quotes, backslashes,
/// whitespace, control characters, and arbitrary URL syntax all fail closed.
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
    /// Pause crossed its irreversible boundary, but bounded state reads could not
    /// prove the result. The caller may retain this only as a recovery candidate;
    /// it must revalidate before treating the source as paused or opening AUHAL.
    case indeterminate(ScriptableMediaSource)
}

enum ScriptableMediaPlayResult: Equatable, Sendable {
    case played
    case stillPaused
    case noLongerPaused
    /// Play may have succeeded even though its receipt was lost. A later recording
    /// must re-read exact state instead of inheriting this as a confirmed pause.
    case indeterminate
}

/// Pure receipt reducer used by the live AppleScript transport and focused race
/// tests. It makes the lost-receipt rule explicit: only an exact PID/track state
/// can become confirmed paused/played; unavailable recovery remains indeterminate.
enum ScriptableMediaCommandResolution {
    static func pauseResult(
        initialSource: ScriptableMediaSource,
        commandObservation: ScriptableMediaPlaybackObservation,
        recoveryObservation: ScriptableMediaPlaybackObservation? = nil
    ) -> ScriptableMediaPauseResult {
        let effective = commandObservation == .unavailable
            ? (recoveryObservation ?? .unavailable)
            : commandObservation
        switch effective {
        case .paused(let source) where source == initialSource:
            return .paused(initialSource)
        case .unavailable:
            return .indeterminate(initialSource)
        case .playing, .paused, .stopped, .notRunning:
            return .notPlaying
        }
    }

    static func playResult(
        expectedSource: ScriptableMediaSource,
        commandObservation: ScriptableMediaPlaybackObservation,
        recoveryObservation: ScriptableMediaPlaybackObservation? = nil
    ) -> ScriptableMediaPlayResult {
        let effective = commandObservation == .unavailable
            ? (recoveryObservation ?? .unavailable)
            : commandObservation
        switch effective {
        case .playing(let source) where source == expectedSource:
            return .played
        case .paused(let source) where source == expectedSource:
            return .stillPaused
        case .unavailable:
            return .indeterminate
        case .playing, .paused, .stopped, .notRunning:
            return .noLongerPaused
        }
    }
}

// MARK: - Bounded Spotify / Music control

/// Uses fixed AppleScript only for Spotify and Music because those apps expose
/// explicit state, Pause, Play, and stable current-track identity. This is not a
/// hardware Play/Pause toggle: every command is state-specific, bounded, and checked
/// against the exact process plus track before VoiceInk++ claims ownership.
///
/// The helper is MainActor-isolated only for `NSWorkspace` process snapshots.
/// `BoundedAppleScriptRunner` performs the blocking Apple Event work on its own queue,
/// so recording UI and shortcut handling remain responsive.
@MainActor
enum AppleScriptMediaControl {
    private static let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "AppleScriptMediaControl"
    )
    private static let commandTimeout: TimeInterval = 1.25
    private static let observationTimeout: TimeInterval = 0.45

    static func isRunning(_ app: ScriptableMediaApp) -> Bool {
        runningProcessIdentifier(for: app) != nil
    }

    /// Reads one exact source, sends one explicit Pause, and reads the post-command
    /// state in that same bounded helper. A separate short read is used only when
    /// the command receipt is lost; the irreversible command is never retried.
    static func pauseIfPlaying(
        _ app: ScriptableMediaApp
    ) async -> ScriptableMediaPauseResult {
        guard case .playing(let initialSource) = await observation(for: app) else {
            return .notPlaying
        }

        let observed = await issueFixedCommand(
            .pause,
            to: initialSource
        )
        let recovery = observed == .unavailable
            ? await observation(for: app)
            : nil
        return ScriptableMediaCommandResolution.pauseResult(
            initialSource: initialSource,
            commandObservation: observed,
            recoveryObservation: recovery
        )
    }

    /// Plays only the exact PID/track previously paused by VoiceInk++. A missing
    /// receipt is not converted into "still paused": callers retain it as an
    /// indeterminate recovery state and revalidate before the next capture.
    static func playIfPaused(
        _ source: ScriptableMediaSource
    ) async -> ScriptableMediaPlayResult {
        switch await observation(for: source.app) {
        case .paused(let current) where current == source:
            break
        case .unavailable:
            return .indeterminate
        case .playing, .paused, .stopped, .notRunning:
            return .noLongerPaused
        }

        let observed = await issueFixedCommand(.play, to: source)
        let recovery = observed == .unavailable
            ? await observation(for: source.app)
            : nil
        return ScriptableMediaCommandResolution.playResult(
            expectedSource: source,
            commandObservation: observed,
            recoveryObservation: recovery
        )
    }

    /// Read-only state used to reconcile a lost Play receipt before another AUHAL
    /// capture opens. It never launches, activates, pauses, or plays an app.
    static func observation(
        for app: ScriptableMediaApp
    ) async -> ScriptableMediaPlaybackObservation {
        guard let processIdentifier = runningProcessIdentifier(for: app) else {
            return .notRunning
        }

        let receipt = await runReceipt(
            app: app,
            timeout: observationTimeout,
            source: """
            if application "\(app.rawValue)" is not running then return "not-running"
            tell application "\(app.rawValue)"
                set stateText to (player state as text)
                if stateText is "stopped" then return "stopped"
                try
                    set trackIdentifier to (\(app.currentTrackIdentifierExpression))
                on error
                    return "unavailable"
                end try
                return stateText & tab & trackIdentifier
            end tell
            """
        )

        return parsedObservation(
            receipt,
            app: app,
            expectedProcessIdentifier: processIdentifier
        )
    }

    private enum FixedCommand: String {
        case pause
        case play

        var requiredState: String {
            switch self {
            case .pause: return "playing"
            case .play: return "paused"
            }
        }
    }

    private static func issueFixedCommand(
        _ command: FixedCommand,
        to source: ScriptableMediaSource
    ) async -> ScriptableMediaPlaybackObservation {
        guard runningProcessIdentifier(for: source.app) == source.processIdentifier else {
            return .notRunning
        }
        let receipt = await runReceipt(
            app: source.app,
            timeout: commandTimeout,
            source: """
            if application "\(source.app.rawValue)" is not running then return "not-running"
            tell application "\(source.app.rawValue)"
                set stateText to (player state as text)
                if stateText is "stopped" then return "stopped"
                try
                    set trackIdentifier to (\(source.app.currentTrackIdentifierExpression))
                on error
                    return "unavailable"
                end try
                if trackIdentifier is not "\(source.trackIdentifier)" then return "source-changed"
                if stateText is not "\(command.requiredState)" then return stateText & tab & trackIdentifier
                \(command.rawValue)
                set stateText to (player state as text)
                if stateText is "stopped" then return "stopped"
                try
                    set trackIdentifier to (\(source.app.currentTrackIdentifierExpression))
                on error
                    return "unavailable"
                end try
                return stateText & tab & trackIdentifier
            end tell
            """
        )
        return parsedObservation(
            receipt,
            app: source.app,
            expectedProcessIdentifier: source.processIdentifier
        )
    }

    private static func parsedObservation(
        _ receipt: String?,
        app: ScriptableMediaApp,
        expectedProcessIdentifier: pid_t
    ) -> ScriptableMediaPlaybackObservation {
        guard runningProcessIdentifier(for: app) == expectedProcessIdentifier else {
            return .unavailable
        }
        guard let receipt else { return .unavailable }
        if receipt == "not-running" { return .notRunning }
        if receipt == "stopped" { return .stopped }
        if receipt == "unavailable" || receipt == "source-changed" {
            return .unavailable
        }

        let fields = receipt.split(
            separator: "\t",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard fields.count == 2 else { return .unavailable }
        let trackIdentifier = String(fields[1])
        guard ScriptableMediaIdentityPolicy.isSafeTrackIdentifier(
            trackIdentifier,
            for: app
        ) else { return .unavailable }

        let source = ScriptableMediaSource(
            app: app,
            processIdentifier: expectedProcessIdentifier,
            trackIdentifier: trackIdentifier
        )
        switch fields[0] {
        case "playing": return .playing(source)
        case "paused": return .paused(source)
        default: return .unavailable
        }
    }

    private static func runningProcessIdentifier(
        for app: ScriptableMediaApp
    ) -> pid_t? {
        let matches = NSRunningApplication.runningApplications(
            withBundleIdentifier: app.bundleId
        ).filter { !$0.isTerminated }
        guard matches.count == 1 else { return nil }
        return matches[0].processIdentifier
    }

    private static func runReceipt(
        app: ScriptableMediaApp,
        timeout: TimeInterval,
        source: String
    ) async -> String? {
        do {
            let result = try await BoundedAppleScriptRunner.run(
                source: source,
                timeout: timeout
            )
            return result.stdout.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        } catch {
            // Never log stdout, track identity, or script source. The fixed app
            // name and bounded error type are sufficient operational telemetry.
            logger.error(
                "Bounded \(app.rawValue, privacy: .public) media operation failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

}

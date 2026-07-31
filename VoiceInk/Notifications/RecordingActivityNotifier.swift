import Foundation

/// Cross-app IPC for the YouTube auto-pause integration.
///
/// WHY THIS EXISTS
/// VoiceInk++ already pauses/resumes media around dictation via `PlaybackController` (Spotify,
/// Apple Music, and any now-playing app reachable through the MediaRemote bridge). But a YouTube
/// video playing in Chrome is NOT reliably pauseable through MediaRemote — Chrome often isn't the
/// "now playing" app, so the media-key / MediaRemote path can't touch it. To cover that case we
/// broadcast lightweight system-wide notifications that a *separate* helper app
/// ("YouTube Spotify Media Key", bundle com.ethan.youtubeSpotifyMediaKey) listens for. That helper
/// owns a Chrome extension which CAN pause/resume the YouTube tab.
///
/// HOW IT WORKS (the contract)
/// We post two `DistributedNotificationCenter` notifications — a system-wide name bus, so the only
/// thing both apps must agree on is the exact name string:
///   - `com.ethansk.voiceink.recordingStarted`  → posted when a dictation recording begins.
///   - `com.ethansk.voiceink.recordingStopped`  → posted when a dictation recording ends.
///   - `com.ethansk.voiceink.recordingStoppedPreservingPlayback` → posted when a genuine Primary
///     triple-click finalizes to the clipboard; consumers must end recording ownership without
///     issuing play, pause, or another playback mutation.
/// These notifications are intentionally scoped to the proven YouTube pause/resume bridge. The
/// rejected ChatGPT Voice mute experiment must not attach another consumer here: neither AXPress nor
/// targeted synthetic input changed that background control reliably, and the pointer workaround
/// stole Ethan's mouse. Keep listener muting disabled unless ChatGPT exposes a documented,
/// non-activating API and Ethan explicitly asks to revisit it.
/// No payload is sent: the helper app already tracks which YouTube tab is playing (via its
/// extension) and decides what to pause/resume. The helper's "only resume what we paused" guard
/// means a `recordingStopped` will NOT start a video that wasn't already playing.
///
/// IMPORTANT — keep these strings in sync with the helper repo's
/// `shared/YoutubeSpotifyMediaKeyShared.swift` (`VoiceInkRecordingNotification`). They are the
/// entire contract; if a name changes on one side and not the other, the integration silently
/// stops working (DistributedNotificationCenter never errors on an unobserved name).
///
/// RELATIONSHIP TO PlaybackController
/// This is COMPLEMENTARY, not a replacement. PlaybackController still handles Spotify/Apple Music/
/// MediaRemote. This notifier only adds the YouTube-via-extension path. We post from the SAME
/// final recorder lifecycle points as PlaybackController.pauseMedia()/resumeMedia() so the two stay
/// in lockstep and we never double-handle the same source (YouTube → extension; everything else →
/// PlaybackController). Capture pause/resume inside one recording deliberately posts neither
/// notification: Ethan controls playback himself during that interval, and the helper must not
/// mistake a microphone pause for a completed recording.
///
/// CANCEL / STOP
/// At the `Recorder` layer, cancel and normal stop both funnel through `stopRecording()`, so both
/// post `recordingStopped`. That's correct here: the helper's resume is guarded by "did we pause
/// something", so a cancel that paused YouTube will correctly resume it, and a cancel that paused
/// nothing is a no-op.
enum RecordingActivityNotifier {
    /// Posted when a dictation recording successfully starts (right where PlaybackController pauses).
    private static let recordingStartedName = Notification.Name("com.ethansk.voiceink.recordingStarted")

    /// Posted when a dictation recording stops/cancels (right where PlaybackController resumes).
    private static let recordingStoppedName = Notification.Name("com.ethansk.voiceink.recordingStopped")

    private static let recordingStoppedPreservingPlaybackName = Notification.Name(
        "com.ethansk.voiceink.recordingStoppedPreservingPlayback"
    )

    /// Broadcast that recording has started. Fire-and-forget; if the helper app isn't running this
    /// is a harmless no-op (DistributedNotificationCenter just has no observers).
    static func postRecordingStarted() {
        DistributedNotificationCenter.default().postNotificationName(
            recordingStartedName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Broadcast that recording has stopped (or been cancelled).
    static func postRecordingStopped() {
        DistributedNotificationCenter.default().postNotificationName(
            recordingStoppedName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Balance a prior `recordingStarted` ownership edge without changing playback.
    /// The YouTube bridge must clear its dictation depth/target but leave the current
    /// video state untouched; this is intentionally distinct from ordinary stop.
    static func postRecordingStoppedPreservingPlayback() {
        DistributedNotificationCenter.default().postNotificationName(
            recordingStoppedPreservingPlaybackName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

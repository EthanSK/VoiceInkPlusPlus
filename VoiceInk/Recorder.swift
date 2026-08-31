import Foundation
import AVFoundation
import CoreAudio
import os
import AppKit

enum RecordingStopPlaybackDisposition: Equatable {
    case restoreOwnedPlayback
    case preserveCurrentPlayback
}

/// Keeps the recording-start safety boundary executable rather than relying only
/// on source ordering. AUHAL must not open until the recording's bounded media
/// pause/join has settled; the start sound marks that boundary for the user.
@MainActor
enum RecordingCaptureStartupSequencer {
    static func run(
        waitForMediaPause: () async -> Void,
        mediaSettled: () -> Void,
        startHardware: () async throws -> Void
    ) async rethrows {
        await waitForMediaPause()
        mediaSettled()
        try await startHardware()
    }
}

@MainActor
class Recorder: NSObject, ObservableObject {
    private var recorder: CoreAudioRecorder?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Recorder")
    private let deviceManager = AudioDeviceManager.shared
    private var deviceSwitchObserver: NSObjectProtocol?
    private var audioDeviceChangedObserver: NSObjectProtocol?
    // Re-prepares the AUHAL after a system wake. See setupWakeObserver for the why.
    private var wakeObserver: NSObjectProtocol?
    private var isReconfiguring = false
    private let mediaController = MediaController.shared
    private let playbackController = PlaybackController.shared
    @Published var audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
    private var audioMeterUpdateTimer: DispatchSourceTimer?
    private let audioMeterQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.audiometer", qos: .userInteractive)
    /// Dedicated serial queue for hardware setup.
    private let audioSetupQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.audioSetup", qos: .userInitiated)
    private var audioMuteTask: Task<Void, Never>?
    private var mediaPauseTask: Task<Void, Never>?
    private var audioRestorationTask: Task<Void, Never>?
    private var recordingMediaPauseLease: RecordingMediaPauseLease?
    private var chatGPTVoiceMuteLease: ChatGPTVoiceCaptureMuteLease?
    private let smoothedValuesLock = NSLock()
    private var smoothedAverage: Float = 0
    private var smoothedPeak: Float = 0

    /// Audio chunk callback for streaming. Can be updated while recording;
    /// changes are forwarded to the live CoreAudioRecorder.
    private var audioChunkGeneration: UInt64 = 0
    private var activeHardwareStopCount = 0
    var onAudioChunk: ((_ data: Data) -> Void)? {
        didSet {
            audioChunkGeneration &+= 1
            // A rapid recording B can reserve its callback while recording A is still
            // stopping on the hardware queue. Do not route A's final PCM into B; B's
            // queued start installs its own captured callback at the exact AUHAL boundary.
            if activeHardwareStopCount == 0 {
                recorder?.onAudioChunk = onAudioChunk
            }
        }
    }
    
    enum RecorderError: Error {
        case couldNotStartRecording
    }
    
    override init() {
        super.init()
        setupDeviceSwitchObserver()
        setupAudioDeviceChangedObserver()
        setupWakeObserver()
        schedulePrepareForCurrentDevice(reason: "init")
    }

    /// Re-prepare the capture hardware after the Mac wakes from sleep.
    ///
    /// ── WHY (clipped-start-of-speech half of the idle-miss bug) ───────────────────
    /// The AUHAL is prepared once at init (and on device changes) but NOT after a wake.
    /// After a long idle period / system sleep the input device can go cold or its AUHAL
    /// state can be torn down, so the FIRST recording cold-starts the unit and the first
    /// few hundred ms of speech are lost (there is no pre-roll ring buffer). Ethan's
    /// report: "there's no buffer — it just misses the start." Re-preparing on wake keeps
    /// the unit warm so the first post-wake press captures from the very first word.
    private func setupWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Don't disturb an in-progress recording; prepare() also early-returns if
                // recording, but skipping here avoids needless setup churn on the audio queue.
                guard !self.deviceManager.isRecordingActive else { return }
                self.schedulePrepareForCurrentDevice(reason: "wake")
            }
        }
    }

    private func setupDeviceSwitchObserver() {
        deviceSwitchObserver = NotificationCenter.default.addObserver(
            forName: .audioDeviceSwitchRequired,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task {
                await self?.handleDeviceSwitchRequired(notification)
            }
        }
    }

    private func setupAudioDeviceChangedObserver() {
        audioDeviceChangedObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("AudioDeviceChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.deviceManager.isRecordingActive else { return }
                self.schedulePrepareForCurrentDevice(reason: "device-changed")
            }
        }
    }

    private func makeCoreAudioRecorder() -> CoreAudioRecorder {
        CoreAudioRecorder { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.deviceManager.isRecordingActive else {
                    // A format notification is advisory during capture. Tearing down AUHAL here
                    // would truncate the open WAV and realtime stream; stopRecording performs the
                    // deferred rebuild immediately after it closes that recording's input gate.
                    self.logger.notice("Selected-device input format changed during capture; reprepare deferred until stop")
                    return
                }
                self.schedulePrepareForCurrentDevice(reason: "input-format-changed")
            }
        }
    }

    private func handleDeviceSwitchRequired(_ notification: Notification) async {
        guard !isReconfiguring else { return }
        guard let recorder = recorder else { return }
        guard let userInfo = notification.userInfo,
              let newDeviceID = userInfo["newDeviceID"] as? AudioDeviceID else {
            logger.error("Device switch notification missing newDeviceID")
            return
        }

        // Prevent concurrent device switches and handleDeviceChange() interference
        isReconfiguring = true
        defer { isReconfiguring = false }

        logger.notice("🎙️ Device switch required: switching to device \(newDeviceID, privacy: .public)")

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                audioSetupQueue.async {
                    do {
                        try recorder.switchDevice(to: newDeviceID)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            // Notify user about the switch
            if let deviceName = deviceManager.availableDevices.first(where: { $0.id == newDeviceID })?.name {
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: String(format: String(localized: "Switched to: %@"), deviceName),
                        type: .info
                    )
                }
            }

            logger.notice("🎙️ Successfully switched recording to device \(newDeviceID, privacy: .public)")
        } catch {
            logger.error("❌ Failed to switch device: \(error, privacy: .public)")

            // If switch fails, stop recording and notify user
            await handleRecordingError(error)
        }
    }

    func startRecording(toOutputFile url: URL) async throws -> RecordingInputDeviceSnapshot? {
        deviceManager.isRecordingActive = true

        let currentDeviceID = deviceManager.getCurrentDevice()
        // Bind History metadata to the same numeric device ID passed to AUHAL. Never read the
        // system default again after startup: it may change while this recording transcribes.
        let inputDeviceSnapshot = deviceManager.recordingInputDeviceSnapshot(for: currentDeviceID)
        let lastDeviceID = UserDefaults.standard.string(forKey: "lastUsedMicrophoneDeviceID")
        if String(currentDeviceID) != lastDeviceID {
            if let deviceName = deviceManager.availableDevices.first(where: { $0.id == currentDeviceID })?.name {
                NotificationManager.shared.showNotification(
                    title: String(format: String(localized: "Using: %@"), deviceName),
                    type: .info
                )
            }
        }
        UserDefaults.standard.set(String(currentDeviceID), forKey: "lastUsedMicrophoneDeviceID")

        let deviceID = currentDeviceID

        audioRestorationTask?.cancel()
        audioRestorationTask = nil
        audioMeterUpdateTimer?.cancel()
        muteSystemAudio()

        let coreAudioRecorder = recorder ?? makeCoreAudioRecorder()
        let callbackForThisStart = onAudioChunk
        recorder = coreAudioRecorder

        // Reserve playback ownership at the synchronous start-intent boundary,
        // before waiting for ChatGPT mute or AUHAL. A rapid recording B must be
        // able to cancel/transfer A's earned resume before media starts playing
        // into B's microphone. The bounded pause task runs concurrently and the
        // catch path below settles it through the same stop/finish lease path.
        let mediaPauseLease = playbackController.beginRecordingPause()
        recordingMediaPauseLease = mediaPauseLease
        if mediaPauseLease.requestsPause {
            pauseMedia(for: mediaPauseLease)
        }
        let startupMediaPauseTask = mediaPauseTask

        do {
            // ChatGPT Voice's built-in mute command is posted directly to its verified PID before
            // AUHAL opens. The best-effort coordinator never activates ChatGPT or touches the
            // pointer, and an absent/inactive/unreadable Voice surface cannot fail recording.
            // Keep the start sound after this bounded preflight so Ethan never starts speaking
            // while listener suppression is still deciding; no mute work runs after the sound.
            let muteLease = await ChatGPTVoiceCaptureMuteCoordinator.shared.prepareForCapture()
            chatGPTVoiceMuteLease = muteLease

            // The media task began concurrently with the listener preflight, but
            // it must settle before AUHAL opens. In the common external-output
            // case it is an immediate no-op. On built-in speakers this prevents
            // Spotify bleed at the start of the WAV; for rapid recordings
            // it also joins any predecessor Play and re-pauses before capture.
            try await RecordingCaptureStartupSequencer.run(
                waitForMediaPause: {
                    await startupMediaPauseTask?.value
                },
                mediaSettled: {
                    SoundManager.shared.playStartSound()
                },
                startHardware: {
                    // Offload hardware start to avoid shortcut lag.
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        audioSetupQueue.async {
                            do {
                                // Install this recording's callback only after every prior queued
                                // stop has closed its input gate. MainActor assignment earlier can
                                // otherwise send the old recording's tail into the new session.
                                coreAudioRecorder.onAudioChunk = callbackForThisStart
                                try coreAudioRecorder.startRecording(toOutputFile: url, deviceID: deviceID)
                                continuation.resume()
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                }
            )

            startAudioMeterTimer()
            // Complementary to the recording media-pause lease: broadcast "recording started" so the external YouTube
            // helper app can pause a playing YouTube tab in Chrome (which MediaRemote can't reach).
            // Posted in the success branch only, so a failed start (which falls into catch →
            // stopRecording) won't emit a started without a matching real recording.
            RecordingActivityNotifier.postRecordingStarted()
            if let inputDeviceSnapshot {
                logger.notice("Recording input captured name=\(inputDeviceSnapshot.name, privacy: .public) uid=\(inputDeviceSnapshot.uid, privacy: .public) file=\(url.lastPathComponent, privacy: .public)")
            } else {
                logger.warning("Recording started without resolvable input-device metadata deviceID=\(deviceID, privacy: .public) file=\(url.lastPathComponent, privacy: .public)")
            }
            return inputDeviceSnapshot
        } catch {
            logger.error("Failed to start recording deviceID=\(deviceID, privacy: .public) file=\(url.lastPathComponent, privacy: .public) error=\(error, privacy: .public)")
            await stopRecording()
            throw RecorderError.couldNotStartRecording
        }
    }

    /// Temporarily releases the microphone while preserving this recording's open
    /// WAV and realtime transcription session.
    ///
    /// Playback deliberately remains untouched. Recording start and final stop own
    /// one media/YouTube-helper pause-resume episode; capture pause/resume must not
    /// manufacture extra lifecycle edges that start or stop media Ethan controls.
    /// We still lift VoiceInk++'s optional system-output mute while capture is paused.
    func pauseRecording() async throws {
        guard let currentRecorder = recorder else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }
        audioMuteTask?.cancel()
        audioMuteTask = nil
        let pendingMediaPause = mediaPauseTask
        mediaPauseTask = nil
        pendingMediaPause?.cancel()
        stopAudioMeter()

        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                audioSetupQueue.async {
                    do {
                        try currentRecorder.pauseRecording()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            // The microphone pause failed, so capture is still live. Settle the
            // canceled best-effort command before reserving a replacement; this
            // keeps exact media ownership ordered without ever putting it ahead
            // of the attempted hardware boundary.
            await pendingMediaPause?.value
            // Capture is still live when the hardware pause fails, so restore the
            // meter and leave media suppression paired with the active recording.
            startAudioMeterTimer()
            muteSystemAudio()
            if let recordingMediaPauseLease {
                pauseMedia(for: recordingMediaPauseLease)
            }
            throw error
        }

        // Hardware capture is already paused. Now join any media command that
        // crossed its irreversible boundary so it cannot mutate playback later.
        // Best-effort media must never delay closing the microphone.
        await pendingMediaPause?.value
        resetAudioMeter()
        if let muteLease = chatGPTVoiceMuteLease {
            chatGPTVoiceMuteLease = nil
            await ChatGPTVoiceCaptureMuteCoordinator.shared.releaseCapture(muteLease)
        }
        audioRestorationTask?.cancel()
        audioRestorationTask = Task {
            guard !Task.isCancelled else { return }
            await mediaController.unmuteSystemAudio()
        }
        logger.info("Recording capture paused; WAV/realtime session remain open and playback is unchanged")
    }

    /// Continues capture into the same WAV/realtime session without changing media
    /// playback or notifying the YouTube helper. The optional output mute is restored
    /// so manually controlled playback is not recorded through the microphone.
    func resumeRecording() async throws {
        audioRestorationTask?.cancel()
        audioRestorationTask = nil

        guard let currentRecorder = recorder else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }
        let muteLease = await ChatGPTVoiceCaptureMuteCoordinator.shared.prepareForCapture()
        chatGPTVoiceMuteLease = muteLease
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                audioSetupQueue.async {
                    do {
                        try currentRecorder.resumeRecording()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            if chatGPTVoiceMuteLease == muteLease {
                chatGPTVoiceMuteLease = nil
            }
            await ChatGPTVoiceCaptureMuteCoordinator.shared.releaseCapture(muteLease)
            throw error
        }

        startAudioMeterTimer()
        muteSystemAudio()
        logger.info("Recording capture resumed into the existing WAV/realtime session; playback is unchanged")
    }

    func stopRecording(
        playbackDisposition: RecordingStopPlaybackDisposition = .restoreOwnedPlayback
    ) async {
        audioMuteTask?.cancel()
        audioMuteTask = nil
        let pendingMediaPause = mediaPauseTask
        mediaPauseTask = nil
        pendingMediaPause?.cancel()
        stopAudioMeter()
        // Capture this generation before awaiting the serial hardware queue. A newer recording may
        // start while this stop is suspended; its lease must not be cleared or restored by us.
        let muteLease = chatGPTVoiceMuteLease
        chatGPTVoiceMuteLease = nil
        let mediaPauseLease = recordingMediaPauseLease
        recordingMediaPauseLease = nil

        // Capture current recorder to stop it on the serial hardware queue.
        let currentRecorder = self.recorder
        let hardwareLogger = logger
        let callbackGenerationAtStop = audioChunkGeneration
        activeHardwareStopCount += 1

        await withCheckedContinuation { continuation in
            audioSetupQueue.async {
                currentRecorder?.stopRecording()
                if let currentRecorder,
                   currentRecorder.hasInvalidatedPreparedInputFormat,
                   currentRecorder.currentDevice != 0 {
                    // The active recording is fully closed before rebuilding. Keeping this on the
                    // serial hardware queue also prevents a rapid successor start from overtaking
                    // the refresh and inheriting the stale same-device format.
                    do {
                        try currentRecorder.prepare(deviceID: currentRecorder.currentDevice)
                        hardwareLogger.notice("Reprepared selected input after deferred format change deviceID=\(currentRecorder.currentDevice, privacy: .public)")
                    } catch {
                        hardwareLogger.warning("Deferred selected-input format reprepare failed deviceID=\(currentRecorder.currentDevice, privacy: .public) error=\(error, privacy: .public)")
                    }
                }
                currentRecorder?.onAudioChunk = nil
                continuation.resume()
            }
        }

        // Clear only after AUHAL's input gate is closed, so every final PCM buffer written
        // to the WAV also reaches realtime. A rapid newer recording can set its callback
        // while this MainActor method awaits the hardware queue; the generation check keeps
        // this older stop from clearing that new owner.
        if audioChunkGeneration == callbackGenerationAtStop {
            onAudioChunk = nil
        }
        activeHardwareStopCount = max(0, activeHardwareStopCount - 1)
        if activeHardwareStopCount == 0 {
            recorder?.onAudioChunk = onAudioChunk
        }

        // AUHAL is closed before this await. The controller checks cancellation
        // before an untouched media command, but completes bounded verification
        // after an irreversible command has begun. Joining here prevents a late
        // unowned pause without extending capture or letting a rapid successor
        // enqueue its start ahead of this recording's stop.
        await pendingMediaPause?.value

        resetAudioMeter()
        if let muteLease {
            await ChatGPTVoiceCaptureMuteCoordinator.shared.releaseCapture(muteLease)
        }

        // Playback owns its own recording-scoped lease and delayed resume. Never
        // hide that work inside audioRestorationTask: a rapid recording must cancel
        // only a pending system-output unmute, while a built-in-speaker successor
        // transfers the paused source and an external-output successor lets it play.
        playbackController.finishRecordingPause(
            mediaPauseLease,
            playbackDisposition: playbackDisposition
        )

        audioRestorationTask?.cancel()
        audioRestorationTask = Task {
            guard !Task.isCancelled else { return }
            await mediaController.unmuteSystemAudio()
        }

        // Complementary to finishing the recording media-pause lease: broadcast "recording stopped" so the external YouTube
        // helper app can resume the tab it paused. Posted synchronously here (not inside the
        // delayed audioRestorationTask) so the resume isn't subject to the audio-resumption delay.
        // The helper only resumes a tab it actually paused, so a spurious stop (e.g. reset on
        // launch) or a cancel is a safe no-op on the YouTube side. Cancel == stop at this layer.
        switch playbackDisposition {
        case .restoreOwnedPlayback:
            RecordingActivityNotifier.postRecordingStopped()
        case .preserveCurrentPlayback:
            RecordingActivityNotifier.postRecordingStoppedPreservingPlayback()
        }

        deviceManager.isRecordingActive = false
    }

    private func muteSystemAudio() {
        audioMuteTask?.cancel()
        audioMuteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            _ = await self.mediaController.muteSystemAudio()
        }
    }

    private func pauseMedia(for lease: RecordingMediaPauseLease) {
        mediaPauseTask?.cancel()
        mediaPauseTask = Task { [weak self] in
            guard let self else { return }
            // Do not return merely because this task was canceled: the controller
            // must first join any predecessor resume and activate this lease. It
            // checks cancellation immediately before issuing a new pause command.
            await self.playbackController.pauseMedia(for: lease)
        }
    }

    private func handleRecordingError(_ error: Error) async {
        logger.error("❌ Recording error occurred: \(error, privacy: .public)")

        // Stop the recording
        await stopRecording()

        // Notify the user about the recording failure
        await MainActor.run {
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Recording Failed: %@"), error.localizedDescription),
                type: .error
            )
        }
    }

    private func startAudioMeterTimer() {
        audioMeterUpdateTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: audioMeterQueue)
        // Thirty frames per second is visually smooth for a 15-bar meter and keeps
        // three mirrored SwiftUI panels from consuming a main-thread update every
        // 17 ms. The visualizer intentionally uses this as its sole animation clock.
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            self?.updateAudioMeter()
        }
        timer.resume()
        audioMeterUpdateTimer = timer
    }

    private func stopAudioMeter() {
        audioMeterUpdateTimer?.cancel()
        audioMeterUpdateTimer = nil
    }

    private func resetAudioMeter() {
        smoothedValuesLock.lock()
        smoothedAverage = 0
        smoothedPeak = 0
        smoothedValuesLock.unlock()
        audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
    }

    private func schedulePrepareForCurrentDevice(reason: String) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return
        }

        let deviceID = deviceManager.getCurrentDevice()
        guard deviceID != 0 else {
            recorder?.teardown()
            return
        }

        let coreAudioRecorder = recorder ?? makeCoreAudioRecorder()
        coreAudioRecorder.onAudioChunk = onAudioChunk
        recorder = coreAudioRecorder

        audioSetupQueue.async { [logger] in
            do {
                try coreAudioRecorder.prepare(deviceID: deviceID)
            } catch {
                logger.warning("Recorder prepare failed reason=\(reason, privacy: .public) deviceID=\(deviceID, privacy: .public) error=\(error, privacy: .public)")
            }
        }
    }

    private func updateAudioMeter() {
        guard let recorder = recorder else { return }

        // Sample audio levels (thread-safe read)
        let averagePower = recorder.averagePower
        let peakPower = recorder.peakPower

        // Normalize values
        let minVisibleDb: Float = -60.0
        let maxVisibleDb: Float = 0.0

        let normalizedAverage: Float
        if averagePower < minVisibleDb {
            normalizedAverage = 0.0
        } else if averagePower >= maxVisibleDb {
            normalizedAverage = 1.0
        } else {
            normalizedAverage = (averagePower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        let normalizedPeak: Float
        if peakPower < minVisibleDb {
            normalizedPeak = 0.0
        } else if peakPower >= maxVisibleDb {
            normalizedPeak = 1.0
        } else {
            normalizedPeak = (peakPower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        // Apply EMA smoothing with thread-safe access
        smoothedValuesLock.lock()
        smoothedAverage = smoothedAverage * 0.6 + normalizedAverage * 0.4
        smoothedPeak = smoothedPeak * 0.6 + normalizedPeak * 0.4
        let newAudioMeter = AudioMeter(averagePower: Double(smoothedAverage), peakPower: Double(smoothedPeak))
        smoothedValuesLock.unlock()

        // Dispatch to main queue for UI updates (more efficient than Task)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.audioMeter = newAudioMeter
        }
    }
    
    // MARK: - Cleanup

    deinit {
        audioMuteTask?.cancel()
        mediaPauseTask?.cancel()
        audioMeterUpdateTimer?.cancel()
        audioRestorationTask?.cancel()
        if let observer = deviceSwitchObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = audioDeviceChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        recorder?.teardown()
    }
}

struct AudioMeter: Equatable {
    let averagePower: Double
    let peakPower: Double
}

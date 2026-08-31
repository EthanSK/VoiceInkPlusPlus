import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import os
import Atomics

/// Restricts dictation to the device's preferred stereo input pair instead of averaging every
/// channel exposed by a multi-channel interface. Devices such as Scarlett can expose many routed
/// inputs; the system-preferred pair is the narrowest safe hint Core Audio provides.
struct AudioInputChannelSelection: Equatable {
    let deviceChannelIndices: [Int32]

    static func resolve(
        deviceChannelCount: UInt32,
        preferredStereoChannels: [UInt32]?
    ) -> AudioInputChannelSelection {
        guard deviceChannelCount > 0 else {
            return AudioInputChannelSelection(deviceChannelIndices: [])
        }

        let fallback = (0..<min(deviceChannelCount, 2)).map(Int32.init)
        guard let preferredStereoChannels,
              !preferredStereoChannels.isEmpty,
              preferredStereoChannels.allSatisfy({ (1...deviceChannelCount).contains($0) }) else {
            return AudioInputChannelSelection(deviceChannelIndices: fallback)
        }

        var seen = Set<UInt32>()
        let preferred = preferredStereoChannels.compactMap { channel -> Int32? in
            guard seen.insert(channel).inserted else { return nil }
            return Int32(channel - 1)
        }
        return AudioInputChannelSelection(deviceChannelIndices: preferred)
    }
}

/// Chooses one signal from a mapped stereo pair without the 6 dB attenuation caused by averaging
/// an active microphone with an idle input. The decision is per render buffer, allocation-free,
/// and also supports mono or full-layout fallback buffers.
struct AudioInputMonoMixdown {
    static func dominantChannelIndex(
        samples: UnsafePointer<Float32>,
        frameCount: Int,
        channelCount: Int
    ) -> Int {
        guard frameCount > 0, channelCount > 1 else { return 0 }

        var dominantChannel = 0
        var dominantEnergy: Double = -1
        for channel in 0..<channelCount {
            var energy: Double = 0
            for frame in 0..<frameCount {
                let sample = Double(samples[frame * channelCount + channel])
                energy += sample * sample
            }
            if energy > dominantEnergy {
                dominantEnergy = energy
                dominantChannel = channel
            }
        }
        return dominantChannel
    }
}

/// Immutable evidence that a prepared AUHAL still describes the selected device.
///
/// Core Audio can keep the same AudioDeviceID while another client changes the device's nominal
/// sample rate. Comparing only device identity then reuses a callback format configured for the old
/// rate and can yield a header-only WAV. Keep both the AUHAL input stream and the device's nominal
/// rate in the reuse boundary; this type never writes either value back to the device.
struct PreparedAudioInputFormat: Equatable {
    let streamSampleRate: Double
    let nominalSampleRate: Double
    let formatID: AudioFormatID
    let formatFlags: AudioFormatFlags
    let bytesPerPacket: UInt32
    let framesPerPacket: UInt32
    let bytesPerFrame: UInt32
    let channelsPerFrame: UInt32
    let bitsPerChannel: UInt32

    init(
        streamFormat: AudioStreamBasicDescription,
        nominalSampleRate: Double
    ) {
        self.streamSampleRate = streamFormat.mSampleRate
        self.nominalSampleRate = nominalSampleRate
        self.formatID = streamFormat.mFormatID
        self.formatFlags = streamFormat.mFormatFlags
        self.bytesPerPacket = streamFormat.mBytesPerPacket
        self.framesPerPacket = streamFormat.mFramesPerPacket
        self.bytesPerFrame = streamFormat.mBytesPerFrame
        self.channelsPerFrame = streamFormat.mChannelsPerFrame
        self.bitsPerChannel = streamFormat.mBitsPerChannel
    }

    static func canReuse(
        prepared: PreparedAudioInputFormat?,
        current: PreparedAudioInputFormat?
    ) -> Bool {
        guard let prepared, let current else { return false }
        return prepared == current
    }
}

private let preparedInputStreamFormatListener: AudioUnitPropertyListenerProc = {
    userData,
    _,
    propertyID,
    scope,
    element
    in
    guard propertyID == kAudioUnitProperty_StreamFormat,
          scope == kAudioUnitScope_Input,
          element == 1 else {
        return
    }
    let recorder = Unmanaged<CoreAudioRecorder>.fromOpaque(userData).takeUnretainedValue()
    recorder.notePreparedInputFormatMayHaveChanged()
}

// MARK: - Core Audio Recorder (AUHAL-based, does not change system default device)
final class CoreAudioRecorder: @unchecked Sendable {

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CoreAudioRecorder")

    private var audioUnit: AudioUnit?
    private var audioFile: ExtAudioFileRef?

    private var isRecording = false
    // Pause keeps the recording file and realtime callback alive, but stops AUHAL.
    // The callback gate is deliberately independent as a final boundary: even a
    // callback already queued when pause begins cannot enter the WAV or stream.
    private var isPaused = false
    private let acceptsInputBuffers = ManagedAtomic(false)
    private var isAudioUnitInitialized = false
    private var currentDeviceID: AudioDeviceID = 0
    private var recordingURL: URL?
    private var preparedInputFormat: PreparedAudioInputFormat?
    private let preparedInputFormatInvalidated = ManagedAtomic(false)
    private var observesInputStreamFormat = false
    private let onPreparedInputFormatChanged: @Sendable () -> Void

    // Device format (what the hardware provides)
    private var deviceFormat = AudioStreamBasicDescription()
    // AUHAL callback format after mapping the device down to physical microphone channels.
    private var captureChannelCount: UInt32 = 1
    // Output format (16kHz mono PCM Int16 for transcription)
    private var outputFormat = AudioStreamBasicDescription()

    // Conversion buffer
    private var conversionBuffer: UnsafeMutablePointer<Int16>?
    private var conversionBufferSize: UInt32 = 0

    // Audio metering (thread-safe)
    private let meterLock = NSLock()
    private var _averagePower: Float = -160.0
    private var _peakPower: Float = -160.0

    var averagePower: Float {
        meterLock.lock()
        defer { meterLock.unlock() }
        return _averagePower
    }

    var peakPower: Float {
        meterLock.lock()
        defer { meterLock.unlock() }
        return _peakPower
    }

    // Pre-allocated render buffer (to avoid malloc in real-time callback)
    private var renderBuffer: UnsafeMutablePointer<Float32>?
    private var renderBufferSize: UInt32 = 0

    /// Called on the audio thread with raw PCM data (16-bit, 16kHz, mono) for streaming.
    private let audioChunkLock = NSLock()
    private var _onAudioChunk: ((_ data: Data) -> Void)?
    var onAudioChunk: ((_ data: Data) -> Void)? {
        get {
            audioChunkLock.lock()
            defer { audioChunkLock.unlock() }
            return _onAudioChunk
        }
        set {
            audioChunkLock.lock()
            _onAudioChunk = newValue
            audioChunkLock.unlock()
        }
    }

    // MARK: - Initialization

    init(onPreparedInputFormatChanged: @escaping @Sendable () -> Void = {}) {
        self.onPreparedInputFormatChanged = onPreparedInputFormatChanged
    }

    deinit {
        teardown()
    }

    // MARK: - Public Interface

    /// Prepares AUHAL for the selected device without starting capture.
    func prepare(deviceID: AudioDeviceID) throws {
        if isRecording {
            return
        }

        try validateDevice(deviceID)

        if isPrepared(for: deviceID) {
            return
        }

        teardownPreparedAudioUnit()
        currentDeviceID = deviceID

        logDeviceDetails(deviceID: deviceID)

        do {
            try createAudioUnit()

            try setInputDevice(deviceID)

            try configureFormats()

            try setupInputCallback()

            try initializeAudioUnit()

            preparedInputFormat = currentInputFormat(for: deviceID)
            guard preparedInputFormat != nil else {
                throw CoreAudioRecorderError.failedToGetDeviceFormat(status: kAudio_ParamError)
            }
            preparedInputFormatInvalidated.store(false, ordering: .releasing)
            setupPreparedInputFormatListener()
        } catch {
            teardownPreparedAudioUnit()
            throw error
        }
    }

    /// Starts recording from the specified device to the given URL (WAV format)
    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID) throws {
        // Stop any existing recording
        stopRecording()

        try prepare(deviceID: deviceID)

        do {
            recordingURL = url

            // The output file is per recording; the AUHAL setup above is reused.
            try createOutputFile(at: url)

            try startAudioUnit()
        } catch {
            isRecording = false
            isPaused = false
            acceptsInputBuffers.store(false, ordering: .releasing)
            closeOutputFile()
            recordingURL = nil
            teardownPreparedAudioUnit()
            throw error
        }
    }

    /// Stops microphone capture without closing the WAV or realtime stream.
    func pauseRecording() throws {
        guard isRecording, !isPaused, let unit = audioUnit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        // Close the callback gate before stopping AUHAL so an in-flight callback
        // cannot append post-pause speech to either output.
        isPaused = true
        acceptsInputBuffers.store(false, ordering: .releasing)
        let status = AudioOutputUnitStop(unit)
        guard status == noErr else {
            isPaused = false
            acceptsInputBuffers.store(true, ordering: .releasing)
            throw CoreAudioRecorderError.failedToStop(status: status)
        }
        resetMeters()
    }

    /// Restarts capture into the same open WAV and realtime stream.
    func resumeRecording() throws {
        guard isRecording, isPaused, let unit = audioUnit, isAudioUnitInitialized else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        // Open the callback gate before AUHAL starts so the first resumed frames are
        // retained. Restore the paused state if the hardware refuses to restart.
        isPaused = false
        acceptsInputBuffers.store(true, ordering: .releasing)
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            isPaused = true
            acceptsInputBuffers.store(false, ordering: .releasing)
            throw CoreAudioRecorderError.failedToStart(status: status)
        }
    }

    /// Stops the current recording
    func stopRecording() {
        guard isRecording || audioFile != nil else {
            return
        }

        let wasRecording = isRecording
        let wasPaused = isPaused
        isRecording = false
        isPaused = false
        acceptsInputBuffers.store(false, ordering: .releasing)

        if wasRecording, let unit = audioUnit {
            if !wasPaused {
                let stopStatus = AudioOutputUnitStop(unit)
                if stopStatus != noErr {
                    logger.warning("🎙️ AudioOutputUnitStop returned \(stopStatus, privacy: .public)")
                }
            }

            let resetStatus = AudioUnitReset(unit, kAudioUnitScope_Global, 0)
            if resetStatus != noErr {
                logger.warning("🎙️ AudioUnitReset returned \(resetStatus, privacy: .public)")
            }
        }

        closeOutputFile()
        recordingURL = nil

        resetMeters()
    }

    /// Releases the prepared AUHAL and buffers. Use for app shutdown or hard recovery.
    func teardown() {
        stopRecording()
        teardownPreparedAudioUnit()
        recordingURL = nil
        currentDeviceID = 0
        resetMeters()
    }

    var isCurrentlyRecording: Bool { isRecording }
    var isCurrentlyPaused: Bool { isPaused }
    var currentRecordingURL: URL? { recordingURL }
    var currentDevice: AudioDeviceID { currentDeviceID }

    static func shouldProcessInputBuffer(isRecording: Bool, isPaused: Bool) -> Bool {
        isRecording && !isPaused
    }

    /// Switches to a new input device mid-recording without stopping the file write
    func switchDevice(to newDeviceID: AudioDeviceID) throws {
        guard isRecording, let unit = audioUnit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        // Don't switch if it's the same device
        guard newDeviceID != currentDeviceID else { return }

        let oldDeviceID = currentDeviceID
        logger.notice("🎙️ Switching recording device from \(oldDeviceID, privacy: .public) to \(newDeviceID, privacy: .public)")

        let wasPaused = isPaused

        // Step 1: Stop the AudioUnit if it is currently capturing (but keep the
        // file open). A paused recording is already stopped and must stay paused
        // after the device switch.
        var status: OSStatus = noErr
        if !wasPaused {
            status = AudioOutputUnitStop(unit)
            if status != noErr {
                logger.warning("🎙️ Warning: AudioOutputUnitStop returned \(status, privacy: .public)")
            }
        }

        // Step 2: Uninitialize to allow reconfiguration
        status = AudioUnitUninitialize(unit)
        if status != noErr {
            logger.warning("🎙️ Warning: AudioUnitUninitialize returned \(status, privacy: .public)")
        }
        isAudioUnitInitialized = false

        // Step 3: Set the new device
        var device = newDeviceID
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status != noErr {
            // Try to recover by restarting with old device
            logger.error("Failed to set new device: \(status, privacy: .public). Attempting recovery...")
            var recoveryDevice = oldDeviceID
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &recoveryDevice, UInt32(MemoryLayout<AudioDeviceID>.size))
            let initializeStatus = AudioUnitInitialize(unit)
            isAudioUnitInitialized = initializeStatus == noErr
            if initializeStatus == noErr, !wasPaused {
                AudioOutputUnitStart(unit)
            }
            throw CoreAudioRecorderError.failedToSetDevice(status: status)
        }

        // Step 4: Get new device format
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var newDeviceFormat = AudioStreamBasicDescription()
        status = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &newDeviceFormat,
            &formatSize
        )

        if status != noErr {
            throw CoreAudioRecorderError.failedToGetDeviceFormat(status: status)
        }

        // Step 5: Configure callback format and map only physical microphone channels.
        let newCaptureChannelCount = try configureCaptureFormat(
            deviceID: newDeviceID,
            deviceFormat: newDeviceFormat
        )

        // Step 6: Reallocate buffers if needed
        let maxFrames: UInt32 = 4096
        let bufferSamples = maxFrames * newCaptureChannelCount
        if bufferSamples > renderBufferSize {
            renderBuffer?.deallocate()
            renderBuffer = UnsafeMutablePointer<Float32>.allocate(capacity: Int(bufferSamples))
            renderBufferSize = bufferSamples
        }

        // Reallocate conversion buffer if new sample rate requires more space
        let maxOutputFrames = UInt32(Double(maxFrames) * (outputFormat.mSampleRate / newDeviceFormat.mSampleRate)) + 1
        if maxOutputFrames > conversionBufferSize {
            conversionBuffer?.deallocate()
            conversionBuffer = UnsafeMutablePointer<Int16>.allocate(capacity: Int(maxOutputFrames))
            conversionBufferSize = maxOutputFrames
        }

        // Update stored format
        deviceFormat = newDeviceFormat
        captureChannelCount = newCaptureChannelCount
        currentDeviceID = newDeviceID

        // Step 7: Reinitialize and restart
        status = AudioUnitInitialize(unit)
        if status != noErr {
            throw CoreAudioRecorderError.failedToInitialize(status: status)
        }
        isAudioUnitInitialized = true

        preparedInputFormat = PreparedAudioInputFormat(
            streamFormat: newDeviceFormat,
            nominalSampleRate: getNominalSampleRate(deviceID: newDeviceID)
                ?? newDeviceFormat.mSampleRate
        )
        preparedInputFormatInvalidated.store(false, ordering: .releasing)

        if !wasPaused {
            status = AudioOutputUnitStart(unit)
            if status != noErr {
                throw CoreAudioRecorderError.failedToStart(status: status)
            }
        }

        logger.notice("🎙️ Successfully switched to device \(newDeviceID, privacy: .public)")
    }

    // MARK: - AudioUnit Setup

    private func createAudioUnit() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            logger.error("AudioUnit not found - HAL Output component unavailable")
            throw CoreAudioRecorderError.audioUnitNotFound
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let audioUnit = unit else {
            logger.error("Failed to create AudioUnit instance: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToCreateAudioUnit(status: status)
        }

        self.audioUnit = audioUnit

        // Enable input on element 1 (input scope)
        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1, // Element 1 = input
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )

        if status != noErr {
            logger.error("Failed to enable audio input: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToEnableInput(status: status)
        }

        // Disable output on element 0 (output scope)
        var disableOutput: UInt32 = 0
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0, // Element 0 = output
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )

        if status != noErr {
            logger.error("Failed to disable audio output: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToDisableOutput(status: status)
        }
    }

    private func setInputDevice(_ deviceID: AudioDeviceID) throws {
        guard let audioUnit = audioUnit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status != noErr {
            logger.error("Failed to set input device \(deviceID, privacy: .public): \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToSetDevice(status: status)
        }
    }

    private func configureFormats() throws {
        guard let audioUnit = audioUnit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        // Get the device's native format (input scope, element 1)
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &deviceFormat,
            &formatSize
        )

        if status != noErr {
            logger.error("Failed to get device format: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToGetDeviceFormat(status: status)
        }

        // Configure output format: 16kHz, mono, PCM Int16
        outputFormat = AudioStreamBasicDescription(
            mSampleRate: 16000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        captureChannelCount = try configureCaptureFormat(
            deviceID: currentDeviceID,
            deviceFormat: deviceFormat
        )

        // Log format details
        let devSampleRate = deviceFormat.mSampleRate
        let devChannels = deviceFormat.mChannelsPerFrame
        let devBits = deviceFormat.mBitsPerChannel
        let outSampleRate = outputFormat.mSampleRate
        let outChannels = outputFormat.mChannelsPerFrame
        let outBits = outputFormat.mBitsPerChannel
        logger.notice("🎙️ Device format: sampleRate=\(devSampleRate, privacy: .public), channels=\(devChannels, privacy: .public), bitsPerChannel=\(devBits, privacy: .public)")
        logger.notice("🎙️ Output format: sampleRate=\(outSampleRate, privacy: .public), channels=\(outChannels, privacy: .public), bitsPerChannel=\(outBits, privacy: .public)")
        if devSampleRate != outSampleRate {
            logger.notice("🎙️ Converting: \(Int(devSampleRate), privacy: .public)Hz → \(Int(outSampleRate), privacy: .public)Hz")
        }

        freeBuffers()

        // Pre-allocate buffers for real-time callback (avoid malloc in callback)
        let maxFrames: UInt32 = 4096
        let bufferSamples = maxFrames * captureChannelCount
        renderBuffer = UnsafeMutablePointer<Float32>.allocate(capacity: Int(bufferSamples))
        renderBufferSize = bufferSamples

        // Pre-allocate conversion buffer (output is always smaller due to downsampling)
        let maxOutputFrames = UInt32(Double(maxFrames) * (outputFormat.mSampleRate / deviceFormat.mSampleRate)) + 1
        conversionBuffer = UnsafeMutablePointer<Int16>.allocate(capacity: Int(maxOutputFrames))
        conversionBufferSize = maxOutputFrames
    }

    private func configureCaptureFormat(
        deviceID: AudioDeviceID,
        deviceFormat: AudioStreamBasicDescription
    ) throws -> UInt32 {
        guard let audioUnit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        let selection = AudioInputChannelSelection.resolve(
            deviceChannelCount: deviceFormat.mChannelsPerFrame,
            preferredStereoChannels: getPreferredInputChannels(deviceID: deviceID)
        )
        let channelCount = UInt32(selection.deviceChannelIndices.count)
        guard channelCount > 0 else {
            throw CoreAudioRecorderError.failedToSetFormat(status: kAudio_ParamError)
        }

        let mappedFormatStatus = setCallbackFormat(
            channelCount: channelCount,
            sampleRate: deviceFormat.mSampleRate,
            audioUnit: audioUnit
        )
        if mappedFormatStatus == noErr {
            var channelMap = selection.deviceChannelIndices
            let mapStatus = channelMap.withUnsafeMutableBytes { bytes in
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_ChannelMap,
                    kAudioUnitScope_Output,
                    1,
                    bytes.baseAddress,
                    UInt32(bytes.count)
                )
            }
            if mapStatus == noErr {
                let mappedChannels = selection.deviceChannelIndices.map { $0 + 1 }
                logger.notice("🎙️ Capturing preferred device input channels: \(mappedChannels, privacy: .public)")
                return channelCount
            }
            logger.error("Preferred audio input channel map was rejected status=\(mapStatus, privacy: .public); falling back to the complete device input layout")
        } else {
            logger.error("Preferred audio input callback format was rejected status=\(mappedFormatStatus, privacy: .public); falling back to the complete device input layout")
        }

        // Channel narrowing is an optimization, never a prerequisite for recording. Restore the
        // same full-device callback format VoiceInk used before this feature. If a previous device
        // left a narrow map on this reusable AUHAL, best-effort reset it to identity; devices that
        // do not implement ChannelMap still retain Core Audio's default identity mapping.
        let fallbackChannelCount = deviceFormat.mChannelsPerFrame
        let fallbackFormatStatus = setCallbackFormat(
            channelCount: fallbackChannelCount,
            sampleRate: deviceFormat.mSampleRate,
            audioUnit: audioUnit
        )
        guard fallbackFormatStatus == noErr else {
            throw CoreAudioRecorderError.failedToSetFormat(status: fallbackFormatStatus)
        }

        var identityMap = (0..<fallbackChannelCount).map { Int32($0) }
        let identityMapStatus = identityMap.withUnsafeMutableBytes { bytes in
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_ChannelMap,
                kAudioUnitScope_Output,
                1,
                bytes.baseAddress,
                UInt32(bytes.count)
            )
        }
        if identityMapStatus != noErr {
            logger.warning("Complete-layout identity channel map was unavailable status=\(identityMapStatus, privacy: .public); using the device's default mapping")
        }
        logger.notice("🎙️ Capturing complete device input layout channels=\(fallbackChannelCount, privacy: .public)")
        return fallbackChannelCount
    }

    private func setCallbackFormat(
        channelCount: UInt32,
        sampleRate: Double,
        audioUnit: AudioUnit
    ) -> OSStatus {
        var callbackFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float32>.size) * channelCount,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float32>.size) * channelCount,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        return AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &callbackFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
    }

    private func setupInputCallback() throws {
        guard let audioUnit = audioUnit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        var callbackStruct = AURenderCallbackStruct(
            inputProc: inputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )

        if status != noErr {
            logger.error("Failed to set input callback: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToSetCallback(status: status)
        }
    }

    private func createOutputFile(at url: URL) throws {
        // Remove existing file if any
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        // Create ExtAudioFile for writing
        var fileRef: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileWAVEType,
            &outputFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &fileRef
        )

        if status != noErr {
            logger.error("Failed to create audio file at \(url.path, privacy: .public): \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToCreateFile(status: status)
        }

        audioFile = fileRef

        // Set client format (what we'll write)
        status = ExtAudioFileSetProperty(
            fileRef!,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &outputFormat
        )

        if status != noErr {
            logger.error("Failed to set file format: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToSetFileFormat(status: status)
        }
    }

    private func initializeAudioUnit() throws {
        guard let audioUnit = audioUnit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        guard !isAudioUnitInitialized else { return }

        let status = AudioUnitInitialize(audioUnit)
        if status != noErr {
            logger.error("Failed to initialize AudioUnit: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToInitialize(status: status)
        }
        isAudioUnitInitialized = true
    }

    private func startAudioUnit() throws {
        guard let audioUnit = audioUnit, isAudioUnitInitialized else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        isRecording = true
        isPaused = false
        acceptsInputBuffers.store(true, ordering: .releasing)
        let status = AudioOutputUnitStart(audioUnit)
        if status != noErr {
            isRecording = false
            isPaused = false
            acceptsInputBuffers.store(false, ordering: .releasing)
            logger.error("Failed to start AudioUnit: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToStart(status: status)
        }
    }

    private func isPrepared(for deviceID: AudioDeviceID) -> Bool {
        guard audioUnit != nil,
              isAudioUnitInitialized,
              currentDeviceID == deviceID,
              isDeviceAvailable(deviceID) else {
            return false
        }

        // Listener delivery is asynchronous and not guaranteed to precede Start. Always re-read
        // the live values at the irreversible reuse boundary as well. A mismatch rebuilds AUHAL;
        // an advisory notification whose values remained identical safely clears the dirty bit.
        let currentFormat = currentInputFormat(for: deviceID)
        guard PreparedAudioInputFormat.canReuse(
            prepared: preparedInputFormat,
            current: currentFormat
        ) else {
            preparedInputFormatInvalidated.store(true, ordering: .releasing)
            logger.notice(
                "Prepared input format is stale; rebuilding AUHAL deviceID=\(deviceID, privacy: .public) preparedStreamRate=\(self.preparedInputFormat?.streamSampleRate ?? -1, privacy: .public) currentStreamRate=\(currentFormat?.streamSampleRate ?? -1, privacy: .public) preparedNominalRate=\(self.preparedInputFormat?.nominalSampleRate ?? -1, privacy: .public) currentNominalRate=\(currentFormat?.nominalSampleRate ?? -1, privacy: .public)"
            )
            return false
        }

        if preparedInputFormatInvalidated.exchange(false, ordering: .acquiringAndReleasing) {
            logger.info("Prepared input format notification revalidated without a material change deviceID=\(deviceID, privacy: .public)")
        }
        return true
    }

    var hasInvalidatedPreparedInputFormat: Bool {
        preparedInputFormatInvalidated.load(ordering: .acquiring)
    }

    fileprivate func notePreparedInputFormatMayHaveChanged() {
        // Property callbacks may arrive on a Core Audio thread. Do no hardware work here. The
        // atomic invalidation makes the next serial prepare fail closed; Recorder may also warm the
        // replacement while idle. During capture, the current unit is deliberately left untouched.
        if !preparedInputFormatInvalidated.exchange(true, ordering: .acquiringAndReleasing) {
            logger.notice("AUHAL reported a selected-device input stream-format change; prepared capture marked stale")
            onPreparedInputFormatChanged()
        }
    }

    private func currentInputFormat(for deviceID: AudioDeviceID) -> PreparedAudioInputFormat? {
        guard let audioUnit else { return nil }

        var currentStreamFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &currentStreamFormat,
            &formatSize
        )
        guard status == noErr else {
            logger.warning("Could not revalidate AUHAL input stream format status=\(status, privacy: .public)")
            return nil
        }

        return PreparedAudioInputFormat(
            streamFormat: currentStreamFormat,
            nominalSampleRate: getNominalSampleRate(deviceID: deviceID)
                ?? currentStreamFormat.mSampleRate
        )
    }

    private func setupPreparedInputFormatListener() {
        guard let audioUnit, !observesInputStreamFormat else { return }
        let status = AudioUnitAddPropertyListener(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            preparedInputStreamFormatListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if status == noErr {
            observesInputStreamFormat = true
        } else {
            // The start-boundary live comparison remains authoritative if a device does not expose
            // property notifications. Listener failure may cost warm reconfiguration, not safety.
            logger.warning("Could not observe AUHAL input stream-format changes status=\(status, privacy: .public)")
        }
    }

    private func validateDevice(_ deviceID: AudioDeviceID) throws {
        if deviceID == 0 {
            logger.error("Cannot start recording - no valid audio device (deviceID is 0)")
            throw CoreAudioRecorderError.failedToSetDevice(status: 0)
        }

        guard isDeviceAvailable(deviceID) else {
            logger.error("Cannot start recording - device \(deviceID, privacy: .public) is no longer available")
            throw CoreAudioRecorderError.deviceNotAvailable
        }
    }

    private func closeOutputFile() {
        if let file = audioFile {
            ExtAudioFileDispose(file)
            audioFile = nil
        }
    }

    private func teardownPreparedAudioUnit() {
        if let unit = audioUnit {
            if observesInputStreamFormat {
                let status = AudioUnitRemovePropertyListenerWithUserData(
                    unit,
                    kAudioUnitProperty_StreamFormat,
                    preparedInputStreamFormatListener,
                    Unmanaged.passUnretained(self).toOpaque()
                )
                if status != noErr {
                    logger.warning("Could not remove AUHAL input stream-format listener status=\(status, privacy: .public)")
                }
            }
            observesInputStreamFormat = false
            AudioOutputUnitStop(unit)
            if isAudioUnitInitialized {
                AudioUnitUninitialize(unit)
            }
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }
        isAudioUnitInitialized = false
        preparedInputFormat = nil
        preparedInputFormatInvalidated.store(false, ordering: .releasing)
        freeBuffers()
    }

    private func freeBuffers() {
        if let buffer = conversionBuffer {
            buffer.deallocate()
            conversionBuffer = nil
            conversionBufferSize = 0
        }

        if let buffer = renderBuffer {
            buffer.deallocate()
            renderBuffer = nil
            renderBufferSize = 0
        }
    }

    private func resetMeters() {
        meterLock.lock()
        _averagePower = -160.0
        _peakPower = -160.0
        meterLock.unlock()
    }

    // MARK: - Input Callback

    private let inputCallback: AURenderCallback = { (
        inRefCon,
        ioActionFlags,
        inTimeStamp,
        inBusNumber,
        inNumberFrames,
        ioData
    ) -> OSStatus in

        let recorder = Unmanaged<CoreAudioRecorder>.fromOpaque(inRefCon).takeUnretainedValue()
        return recorder.handleInputBuffer(
            ioActionFlags: ioActionFlags,
            inTimeStamp: inTimeStamp,
            inBusNumber: inBusNumber,
            inNumberFrames: inNumberFrames
        )
    }

    private func handleInputBuffer(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32
    ) -> OSStatus {

        guard let audioUnit = audioUnit,
              acceptsInputBuffers.load(ordering: .acquiring),
              let renderBuf = renderBuffer else {
            return noErr
        }

        // Use pre-allocated buffer for input data
        let channelCount = captureChannelCount
        let requiredSamples = inNumberFrames * channelCount

        // Safety check - shouldn't happen with 4096 max frames
        guard requiredSamples <= renderBufferSize else {
            return noErr
        }

        let bytesPerFrame = UInt32(MemoryLayout<Float32>.size) * channelCount
        let bufferSize = inNumberFrames * bytesPerFrame

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: channelCount,
                mDataByteSize: bufferSize,
                mData: renderBuf
            )
        )

        // Render audio from the input
        let status = AudioUnitRender(
            audioUnit,
            ioActionFlags,
            inTimeStamp,
            inBusNumber,
            inNumberFrames,
            &bufferList
        )

        if status != noErr {
            return status
        }

        // Pause can race a callback that passed the entry gate just before AUHAL
        // stopped. Recheck after render and before either irreversible sink.
        guard acceptsInputBuffers.load(ordering: .acquiring) else {
            return noErr
        }

        // Calculate audio meters from input buffer
        calculateMeters(from: &bufferList, frameCount: inNumberFrames)

        // Convert and write to file
        convertAndWriteToFile(inputBuffer: &bufferList, frameCount: inNumberFrames)

        return noErr
    }

    private func calculateMeters(from bufferList: inout AudioBufferList, frameCount: UInt32) {
        guard let data = bufferList.mBuffers.mData else { return }
        guard frameCount > 0 else { return }

        let samples = data.assumingMemoryBound(to: Float32.self)
        let channelCount = Int(bufferList.mBuffers.mNumberChannels)
        guard channelCount > 0 else { return }
        let dominantChannel = AudioInputMonoMixdown.dominantChannelIndex(
            samples: samples,
            frameCount: Int(frameCount),
            channelCount: channelCount
        )

        var sum: Float = 0.0
        var peak: Float = 0.0

        for frame in 0..<Int(frameCount) {
            let sample = abs(samples[frame * channelCount + dominantChannel])
            sum += sample * sample
            if sample > peak {
                peak = sample
            }
        }

        let rms = sqrt(sum / Float(frameCount))
        let avgDb = 20.0 * log10(max(rms, 0.000001))
        let peakDb = 20.0 * log10(max(peak, 0.000001))

        meterLock.lock()
        _averagePower = avgDb
        _peakPower = peakDb
        meterLock.unlock()
    }

    private func convertAndWriteToFile(inputBuffer: inout AudioBufferList, frameCount: UInt32) {
        guard let file = audioFile else { return }

        let inputChannels = Int(inputBuffer.mBuffers.mNumberChannels)
        let inputSampleRate = deviceFormat.mSampleRate
        let outputSampleRate = outputFormat.mSampleRate

        // Get input samples
        guard let inputData = inputBuffer.mBuffers.mData else { return }
        let inputSamples = inputData.assumingMemoryBound(to: Float32.self)
        guard inputChannels > 0 else { return }
        let dominantChannel = AudioInputMonoMixdown.dominantChannelIndex(
            samples: inputSamples,
            frameCount: Int(frameCount),
            channelCount: inputChannels
        )

        // Calculate output frame count after sample rate conversion
        let ratio = outputSampleRate / inputSampleRate
        let outputFrameCount = UInt32(Double(frameCount) * ratio)

        guard outputFrameCount > 0,
              let outputBuffer = conversionBuffer,
              outputFrameCount <= conversionBufferSize else { return }

        // Convert Float32 multi-channel → Int16 mono (with sample rate conversion if needed)
        if inputSampleRate == outputSampleRate {
            // Direct conversion from the strongest mapped input. Averaging an active mono mic
            // with an idle stereo partner would attenuate speech by 6 dB.
            for i in 0..<Int(frameCount) {
                let sample = inputSamples[i * inputChannels + dominantChannel]

                // Convert to Int16 with clipping
                let scaled = sample * 32767.0
                let clipped = max(-32768.0, min(32767.0, scaled))
                outputBuffer[i] = Int16(clipped)
            }
        } else {
            // Sample rate conversion needed - use linear interpolation
            for i in 0..<Int(outputFrameCount) {
                let inputIndex = Double(i) / ratio
                let inputIndexInt = Int(inputIndex)
                let frac = Float32(inputIndex - Double(inputIndexInt))

                let idx1 = min(inputIndexInt, Int(frameCount) - 1)
                let idx2 = min(inputIndexInt + 1, Int(frameCount) - 1)

                let s1 = inputSamples[idx1 * inputChannels + dominantChannel]
                let s2 = inputSamples[idx2 * inputChannels + dominantChannel]
                let sample = s1 + frac * (s2 - s1)

                // Convert to Int16
                let scaled = sample * 32767.0
                let clipped = max(-32768.0, min(32767.0, scaled))
                outputBuffer[i] = Int16(clipped)
            }
        }

        // Write to file
        var outputBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: outputFrameCount * 2,
                mData: outputBuffer
            )
        )

        let writeStatus = ExtAudioFileWrite(file, outputFrameCount, &outputBufferList)
        if writeStatus != noErr {
            logger.error("🎙️ ExtAudioFileWrite failed with status: \(writeStatus, privacy: .public)")
        }

        // Send the same PCM data to the streaming callback if set.
        if let audioChunk = onAudioChunk {
            let byteCount = Int(outputFrameCount) * MemoryLayout<Int16>.size
            let data = Data(bytes: outputBuffer, count: byteCount)
            audioChunk(data)
        }
    }

    // MARK: - Device Info Logging

    private func logDeviceDetails(deviceID: AudioDeviceID) {
        // Get device name
        let deviceName = getDeviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceNameCFString) ?? "Unknown"

        // Get device UID
        let deviceUID = getDeviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "Unknown"

        // Get transport type
        let transportType = getTransportType(deviceID: deviceID)

        // Get manufacturer
        let manufacturer = getDeviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceManufacturerCFString) ?? "Unknown"

        logger.notice("🎙️ Device info: name=\(deviceName, privacy: .public), uid=\(deviceUID, privacy: .public)")
        logger.notice("🎙️ Device details: transport=\(transportType, privacy: .public), manufacturer=\(manufacturer, privacy: .public)")

        // Get buffer frame size
        if let bufferSize = getBufferFrameSize(deviceID: deviceID) {
            let latencyMs = (Double(bufferSize) / 48000.0) * 1000.0 // Approximate latency assuming 48kHz
            logger.notice("🎙️ Buffer size: \(bufferSize, privacy: .public) frames, ~latency: \(String(format: "%.1f", latencyMs), privacy: .public)ms")
        }
    }

    private func getDeviceStringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize = UInt32(MemoryLayout<CFString>.size)
        var property: CFString?

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &property
        )

        if status == noErr, let cfString = property {
            return cfString as String
        }
        return nil
    }

    private func getTransportType(deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var transportType: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &transportType
        )

        if status != noErr {
            return "Unknown"
        }

        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return "Built-in"
        case kAudioDeviceTransportTypeUSB:
            return "USB"
        case kAudioDeviceTransportTypeBluetooth:
            return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE:
            return "Bluetooth LE"
        case kAudioDeviceTransportTypeAggregate:
            return "Aggregate"
        case kAudioDeviceTransportTypeVirtual:
            return "Virtual"
        case kAudioDeviceTransportTypePCI:
            return "PCI"
        case kAudioDeviceTransportTypeFireWire:
            return "FireWire"
        case kAudioDeviceTransportTypeDisplayPort:
            return "DisplayPort"
        case kAudioDeviceTransportTypeHDMI:
            return "HDMI"
        case kAudioDeviceTransportTypeAVB:
            return "AVB"
        case kAudioDeviceTransportTypeThunderbolt:
            return "Thunderbolt"
        default:
            return "Other (\(transportType))"
        }
    }

    private func getBufferFrameSize(deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var bufferSize: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &bufferSize
        )

        return status == noErr ? bufferSize : nil
    }

    private func getNominalSampleRate(deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var propertySize = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &sampleRate
        )
        guard status == noErr, sampleRate > 0 else { return nil }
        return sampleRate
    }

    private func getPreferredInputChannels(deviceID: AudioDeviceID) -> [UInt32]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        var channels = [UInt32](repeating: 0, count: 2)
        var propertySize = UInt32(MemoryLayout<UInt32>.size * channels.count)
        let status = channels.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &propertySize,
                bytes.baseAddress!
            )
        }
        let expectedSize = UInt32(MemoryLayout<UInt32>.size * channels.count)
        return status == noErr && propertySize == expectedSize ? channels : nil
    }

    /// Checks if a device is currently available using Apple's kAudioDevicePropertyDeviceIsAlive
    private func isDeviceAvailable(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isAlive: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &isAlive
        )

        return status == noErr && isAlive == 1
    }
}

// MARK: - Error Types

enum CoreAudioRecorderError: LocalizedError {
    case audioUnitNotFound
    case audioUnitNotInitialized
    case deviceNotAvailable
    case failedToCreateAudioUnit(status: OSStatus)
    case failedToEnableInput(status: OSStatus)
    case failedToDisableOutput(status: OSStatus)
    case failedToSetDevice(status: OSStatus)
    case failedToGetDeviceFormat(status: OSStatus)
    case failedToSetFormat(status: OSStatus)
    case failedToSetCallback(status: OSStatus)
    case failedToCreateFile(status: OSStatus)
    case failedToSetFileFormat(status: OSStatus)
    case failedToInitialize(status: OSStatus)
    case failedToStart(status: OSStatus)
    case failedToStop(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .audioUnitNotFound:
            return String(localized: "HAL Output AudioUnit not found")
        case .audioUnitNotInitialized:
            return String(localized: "AudioUnit not initialized")
        case .deviceNotAvailable:
            return String(localized: "Audio device is no longer available")
        case .failedToCreateAudioUnit(let status):
            return String(format: String(localized: "Failed to create AudioUnit: %lld"), Int64(status))
        case .failedToEnableInput(let status):
            return String(format: String(localized: "Failed to enable input: %lld"), Int64(status))
        case .failedToDisableOutput(let status):
            return String(format: String(localized: "Failed to disable output: %lld"), Int64(status))
        case .failedToSetDevice(let status):
            return String(format: String(localized: "Failed to set input device: %lld"), Int64(status))
        case .failedToGetDeviceFormat(let status):
            return String(format: String(localized: "Failed to get device format: %lld"), Int64(status))
        case .failedToSetFormat(let status):
            return String(format: String(localized: "Failed to set audio format: %lld"), Int64(status))
        case .failedToSetCallback(let status):
            return String(format: String(localized: "Failed to set input callback: %lld"), Int64(status))
        case .failedToCreateFile(let status):
            return String(format: String(localized: "Failed to create audio file: %lld"), Int64(status))
        case .failedToSetFileFormat(let status):
            return String(format: String(localized: "Failed to set file format: %lld"), Int64(status))
        case .failedToInitialize(let status):
            return String(format: String(localized: "Failed to initialize AudioUnit: %lld"), Int64(status))
        case .failedToStart(let status):
            return String(format: String(localized: "Failed to start AudioUnit: %lld"), Int64(status))
        case .failedToStop(let status):
            return String(format: String(localized: "Failed to pause AudioUnit: %lld"), Int64(status))
        }
    }
}

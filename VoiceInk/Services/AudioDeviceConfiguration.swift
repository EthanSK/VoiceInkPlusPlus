import Foundation
import AVFoundation
import CoreAudio
import os

struct DefaultOutputDeviceSnapshot: Equatable {
    let deviceID: AudioDeviceID
    let uid: String
    let transportType: AudioDevicePropertyID
}

/// Observe route changes even when the selected microphone's ID and format stay unchanged.
/// In particular, a Bluetooth output round trip can invalidate an input-only AUHAL. This class
/// only reports topology changes; it never changes a system device or touches capture hardware.
final class AudioHardwareRouteObserver {
    static let selectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        kAudioHardwarePropertyDevices
    ]

    private let listener: AudioObjectPropertyListenerBlock
    private var registeredSelectors: [AudioObjectPropertySelector] = []

    init(onChange: @escaping @Sendable () -> Void) {
        listener = { _, _ in onChange() }
        for selector in Self.selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
            )
            if status == noErr {
                registeredSelectors.append(selector)
            } else {
                Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Recorder")
                    .error("Audio route listener registration failed selector=\(selector, privacy: .public) status=\(status, privacy: .public)")
            }
        }
    }

    deinit {
        // Remove the exact registered block/queue/address tuple; a newly constructed closure
        // does not unregister a listener and can leave callbacks targeting a dead owner.
        for selector in registeredSelectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
            )
        }
    }
}

/// Audio device configuration queries (does NOT modify system default device)
class AudioDeviceConfiguration {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioDeviceConfiguration")

    /// Gets the current system default input device (for reference only)
    static func getDefaultInputDevice() -> AudioDeviceID? {
        var defaultDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &defaultDeviceID
        )
        if status != noErr {
            logger.error("Failed to get current default input device: \(status, privacy: .public)")
            return nil
        }
        return defaultDeviceID
    }

    /// Captures the exact system output route used for one recording decision.
    ///
    /// The built-in-speaker media rule deliberately uses Core Audio identity rather
    /// than a localized display name. USB interfaces and renamed aggregate devices
    /// can contain words such as "MacBook" or "Speakers" without being the internal
    /// transducers beside the microphone.
    static func getDefaultOutputDeviceSnapshot() -> DefaultOutputDeviceSnapshot? {
        var deviceID = AudioDeviceID(0)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            0,
            nil,
            &deviceSize,
            &deviceID
        )
        guard deviceStatus == noErr, deviceID != 0 else {
            logger.warning("Failed to resolve default output device status=\(deviceStatus, privacy: .public)")
            return nil
        }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidValue: CFString?
        let uidStatus = AudioObjectGetPropertyData(
            deviceID,
            &uidAddress,
            0,
            nil,
            &uidSize,
            &uidValue
        )

        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportSize = UInt32(MemoryLayout<AudioDevicePropertyID>.size)
        var transportType = AudioDevicePropertyID(0)
        let transportStatus = AudioObjectGetPropertyData(
            deviceID,
            &transportAddress,
            0,
            nil,
            &transportSize,
            &transportType
        )

        guard uidStatus == noErr,
              let uidValue,
              transportStatus == noErr else {
            logger.warning(
                "Failed to resolve default output identity uidStatus=\(uidStatus, privacy: .public) transportStatus=\(transportStatus, privacy: .public)"
            )
            return nil
        }

        return DefaultOutputDeviceSnapshot(
            deviceID: deviceID,
            uid: uidValue as String,
            transportType: transportType
        )
    }

    static func isMacBookBuiltInSpeakers(
        uid: String,
        transportType: AudioDevicePropertyID
    ) -> Bool {
        uid == "BuiltInSpeakerDevice" &&
            transportType == kAudioDeviceTransportTypeBuiltIn
    }

    static func isMacBookBuiltInSpeakers(
        _ snapshot: DefaultOutputDeviceSnapshot?
    ) -> Bool {
        guard let snapshot else { return false }
        return isMacBookBuiltInSpeakers(
            uid: snapshot.uid,
            transportType: snapshot.transportType
        )
    }

    /// Creates a device change observer that calls handler on the specified queue
    static func createDeviceChangeObserver(
        handler: @escaping () -> Void,
        queue: OperationQueue = .main
    ) -> NSObjectProtocol {
        return NotificationCenter.default.addObserver(
            forName: NSNotification.Name("AudioDeviceChanged"),
            object: nil,
            queue: queue,
            using: { _ in handler() }
        )
    }
}

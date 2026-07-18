import Foundation

/// Runtime escape hatches for delivery behavior that is intentionally riskier or
/// still under live compatibility development. Keep these flags separate from the
/// three mouse-button destination routes: changing a flag selects the delivery engine,
/// not a fourth destination or a reinterpretation of Primary/Next.
enum VoiceInkDeliveryFeatureFlags {
    /// `false` is the temporary safe default while exact saved-input delivery is being
    /// repaired against real Codex surfaces. In that state VoiceInk++ behaves like base
    /// VoiceInk: Primary records normally, the finished transcript goes to whichever
    /// input owns keyboard focus at delivery, and Next Track is not intercepted.
    ///
    /// This is a real runtime UserDefaults flag so Settings and `defaults write` can
    /// switch engines without rebuilding. A future release may change the default only
    /// after physical background-delivery testing passes; an explicit user value always
    /// wins so Ethan can immediately fall back again if a regression escapes testing.
    static let exactInputDeliveryDefaultsKey =
        "VIPPExactInputDeliveryEnabled"
    static let exactInputDeliveryDefault = false

    static func exactInputDeliveryEnabled(
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.object(
            forKey: exactInputDeliveryDefaultsKey
        ) != nil else {
            return exactInputDeliveryDefault
        }
        return defaults.bool(forKey: exactInputDeliveryDefaultsKey)
    }

    /// The second recorder icon represents a saved exact input and the Next-button
    /// routes that can act on it. Compatibility mode deliberately captures neither,
    /// so rendering an empty slot would turn an intentional nil target into a false
    /// warning. Keep this policy shared by mini, notch, and stacked-session UI.
    static func shouldShowLockedDestinationIndicator(
        recordingState: RecordingState,
        isExactInputDeliveryEnabled: Bool = exactInputDeliveryEnabled()
    ) -> Bool {
        guard isExactInputDeliveryEnabled else { return false }
        switch recordingState {
        case .starting, .recording, .transcribing, .enhancing:
            return true
        case .idle, .busy:
            return false
        }
    }
}

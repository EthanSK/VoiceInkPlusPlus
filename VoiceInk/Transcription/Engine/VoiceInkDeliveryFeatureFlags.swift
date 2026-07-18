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

    /// Keep the locked-destination slot visible for every active session. In exact
    /// mode it shows the captured app/input. In compatibility mode there is
    /// deliberately no saved input, so the warning icon is useful and honest: it
    /// makes clear that Next-button destination ownership is unavailable instead of
    /// silently collapsing the two-icon recorder into a different layout.
    static func shouldShowLockedDestinationIndicator(
        recordingState: RecordingState
    ) -> Bool {
        switch recordingState {
        case .starting, .recording, .transcribing, .enhancing:
            return true
        case .idle, .busy:
            return false
        }
    }
}

import SwiftUI
import AppKit

// MARK: - App Version

/// The two-line release identifier shown immediately before Stop. Keeping its
/// presentation separate from Bundle lookup makes the exact split testable:
/// `v2.0` is the product version and `.NNN` is the uniquely released build.
struct RecorderVersionPresentation: Equatable {
    let topLine: String
    let bottomLine: String?
    let accessibilityLabel: String

    init(marketingVersion: String?, buildNumber: String?) {
        let marketing = marketingVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = buildNumber?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (marketing, build) {
        case let (marketing?, build?) where !marketing.isEmpty && !build.isEmpty:
            topLine = "v\(marketing)"
            bottomLine = ".\(build)"
            accessibilityLabel = "VoiceInk++ version \(marketing), build \(build)"
        case let (marketing?, _) where !marketing.isEmpty:
            topLine = "v\(marketing)"
            bottomLine = nil
            accessibilityLabel = "VoiceInk++ version \(marketing)"
        case let (_, build?) where !build.isEmpty:
            topLine = "v?"
            bottomLine = ".\(build)"
            accessibilityLabel = "VoiceInk++ build \(build)"
        default:
            topLine = "v?"
            bottomLine = nil
            accessibilityLabel = "VoiceInk++ version unavailable"
        }
    }
}

/// The build number increments for every installed VoiceInk++ release, while
/// the marketing version changes only for product milestones. The two rows use
/// the recorder's otherwise unused vertical space to stay legible at a glance.
struct RecorderVersionLabel: View {
    private static let marketingVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String
    private static let buildNumber = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion"
    ) as? String

    private static let presentation = RecorderVersionPresentation(
        marketingVersion: marketingVersion,
        buildNumber: buildNumber
    )

    var body: some View {
        VStack(spacing: -2) {
            Text(Self.presentation.topLine)

            if let bottomLine = Self.presentation.bottomLine {
                Text(bottomLine)
            }
        }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.48))
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: true, vertical: true)
            .frame(minWidth: 28, alignment: .center)
            .help(Self.presentation.accessibilityLabel)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(Self.presentation.accessibilityLabel))
    }
}

// MARK: - Icon Toggle Button

struct RecorderToggleButton: View {
    let isEnabled: Bool
    let icon: String
    let disabled: Bool
    let action: () -> Void

    init(isEnabled: Bool, icon: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.icon = icon
        self.disabled = disabled
        self.action = action
    }

    private var isEmoji: Bool {
        !icon.contains(".") && !icon.contains("-") && icon.unicodeScalars.contains { !$0.isASCII }
    }

    var body: some View {
        Button(action: action) {
            Group {
                if isEmoji {
                    Text(icon).font(.system(size: 14))
                } else {
                    Image(systemName: icon).font(.system(size: 13))
                }
            }
            .foregroundColor(disabled ? .white.opacity(0.3) : (isEnabled ? .white : .white.opacity(0.6)))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(disabled)
    }
}

// MARK: - Record Button

struct RecorderRecordButton: View {
    let recordingState: RecordingState
    let action: () -> Void

    private var visualState: VisualState {
        switch recordingState {
        case .idle, .starting, .busy:
            return .ready
        case .recording:
            return .recording
        case .transcribing, .enhancing:
            return .processing
        }
    }

    private var isDisabled: Bool {
        switch recordingState {
        case .idle, .recording:
            return false
        case .starting, .transcribing, .enhancing, .busy:
            return true
        }
    }

    var body: some View {
        Button(action: action) {
            buttonFace
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(accessibilityLabel)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var buttonFace: some View {
        ZStack {
            Circle()
                .fill(colors.surface)
                .overlay(
                    Circle()
                        .strokeBorder(colors.border, lineWidth: 0.6)
                )

            stateMark
        }
        .frame(width: 21, height: 21)
        .contentShape(Circle())
        .animation(.easeOut(duration: 0.16), value: visualState)
    }

    private var colors: StateColors {
        switch visualState {
        case .ready:
            return StateColors(
                surface: Color(red: 0.30, green: 0.30, blue: 0.32),
                border: Color(red: 0.42, green: 0.42, blue: 0.44),
                mark: Color(red: 0.78, green: 0.78, blue: 0.80)
            )
        case .recording:
            let red = AppTheme.Status.error
            return StateColors(
                surface: red.opacity(0.92),
                border: red.opacity(0.98),
                mark: .white
            )
        case .processing:
            return StateColors(
                surface: Color.white.opacity(0.13),
                border: Color.white.opacity(0.18),
                mark: Color.white.opacity(0.86)
            )
        }
    }

    @ViewBuilder
    private var stateMark: some View {
        switch visualState {
        case .ready, .recording:
            RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                .fill(colors.mark)
                .frame(width: 8, height: 8)
        case .processing:
            ProcessingIndicator(color: colors.mark)
        }
    }

    private var accessibilityLabel: String {
        switch recordingState {
        case .idle:
            return String(localized: "Start recording")
        case .starting:
            return String(localized: "Starting recording")
        case .recording:
            return String(localized: "Stop recording")
        case .transcribing:
            return String(localized: "Transcribing recording")
        case .enhancing:
            return String(localized: "Enhancing recording")
        case .busy:
            return String(localized: "Recorder unavailable")
        }
    }

    private enum VisualState: Equatable {
        case ready
        case recording
        case processing
    }

    private struct StateColors {
        let surface: Color
        let border: Color
        let mark: Color
    }
}

// MARK: - Close Button

struct RecorderCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.13))
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
                    )

                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.86))
            }
            .frame(width: 21, height: 21)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Close")
    }
}

// MARK: - Cancel (Discard) Button
//
// VIPP (cancel-recording feature): a dedicated red "X" button that lives RIGHT NEXT
// TO the record/stop control in every recorder panel. Ethan wants a one-tap way to
// ABORT a recording (or an in-flight transcription) WITHOUT delivering/pasting any
// text — distinct from the normal Stop control, which finishes + transcribes + pastes.
//
// WHY a separate component (not the grey RecorderCloseButton):
//   - RecorderCloseButton is grey + only shown for the assistant-idle "close" affordance.
//     Reusing it would visually conflate "discard this recording" with "dismiss the
//     assistant panel". This button is RED so it reads unambiguously as a destructive
//     abort, and it's always adjacent to Stop while a recording/transcription is live.
//
// WIRING: the tap calls the `action` closure, which the panels route to
// RecorderUIManager.cancelRecording() → VoiceInkEngine.cancelRecording(). That path:
//   • aborts/poisons any in-flight transcription pipeline so its result is DISCARDED,
//     never pasted (see requestRecordingCancellation / canceledPipelineTranscriptionIDs),
//   • stops audio capture via recorder.stopRecording(), which is the SAME stop path
//     normal Stop uses and therefore resumes paused Spotify/Music (playbackController
//     .resumeMedia()) + unmutes system audio,
//   • clears the partial transcript + recorded file, returns state to .idle,
//   • then dismisses the recorder panel.
// It is idempotent/safe if pressed when nothing is active (the engine's .idle/.busy
// branch just resets state).
struct RecorderCancelButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    // Subtle red-tinted fill so the control is clearly an abort, but
                    // not as loud as the solid-red recording indicator on the Stop button.
                    .fill(AppTheme.Status.error.opacity(0.20))
                    .overlay(
                        Circle()
                            .strokeBorder(AppTheme.Status.error.opacity(0.55), lineWidth: 0.6)
                    )

                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(AppTheme.Status.error)
            }
            // Match the 21pt hit-target sizing of the record/close buttons so it lines
            // up cleanly beside Stop in both the mini bar and the notch pill.
            .frame(width: 21, height: 21)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Cancel recording (discard, no paste)")
        .accessibilityLabel(Text("Cancel recording"))
    }
}

// MARK: - Skip Mode Processing (Raw Transcript) Toggle Button
//
// VIPP (skip-mode-processing feature): a one-shot TOGGLE that sits immediately to the
// RIGHT of the red Cancel ("X") button on the recorder, available WHILE a recording is
// live. When ENGAGED for the current recording, that single dictation skips the active
// Mode's post-transcription processing — both the AI enhancement AND any custom-command/
// script the Mode would run afterward — and pastes the RAW verbatim transcript instead.
//
// ── ONE-SHOT, PER-SESSION SEMANTICS ─────────────────────────────────────────────
// The toggle reads/writes the OBSERVED RecordingSession's `skipPostProcessing` flag
// (via the RecorderStateProvider protocol). It does NOT change the user's default
// Mode/settings: it's scoped to THIS recording only, and the next recording starts a
// fresh RecordingSession with the flag back at false. The user decides DURING the
// recording that this one should be raw; the engine's pipeline reads the flag at
// transcribe/deliver time, so toggling any time before that step is honored.
//
// ── STATE MODEL (clear ON/OFF) ──────────────────────────────────────────────────
// The button has a deliberate at-a-glance on/off look so the user can see whether THIS
// session will skip processing:
//   • OFF (default) → subdued: faint white fill + dimmed "bolt.slash" glyph. Reads as
//     "available but not engaged".
//   • ON (engaged)  → active: amber-tinted fill + bordered + solid amber filled glyph
//     ("bolt.slash.fill"). Reads unambiguously as "this recording WILL skip processing".
// Amber (warningStrong / systemOrange) is intentionally distinct from the red Cancel
// button beside it (they must not be confused) and from the neutral record control.
//
// ── SF SYMBOL CHOICE ────────────────────────────────────────────────────────────
// VoiceInk Modes are branded "Power Mode" / ⚡, so `bolt.slash` = "disable the mode's
// power for this one recording". We swap to the `.fill` variant when engaged to amplify
// the on-state.
//
// ── BINDING ─────────────────────────────────────────────────────────────────────
// Driven by a SwiftUI Binding<Bool> the parent view derives from its observed
// stateProvider's skipPostProcessing (see Mini/NotchRecorderView). Because the card
// observes its own RecordingSession (@ObservedObject), flipping the flag re-renders this
// button immediately — same per-session-observation pattern the rest of the recorder uses.
struct RecorderSkipProcessingButton: View {
    @Binding var isEngaged: Bool

    // Amber accent for the engaged state — matches the "power mode disabled" intent and is
    // visually separate from the adjacent red Cancel button.
    private let engagedAccent = AppTheme.Status.warningStrong

    var body: some View {
        Button(action: { isEngaged.toggle() }) {
            ZStack {
                Circle()
                    // ON → amber-tinted fill; OFF → the same faint neutral fill the
                    // close/processing controls use, so an un-engaged button is quiet.
                    .fill(isEngaged ? engagedAccent.opacity(0.22) : Color.white.opacity(0.13))
                    .overlay(
                        Circle()
                            .strokeBorder(
                                isEngaged ? engagedAccent.opacity(0.85) : Color.white.opacity(0.18),
                                lineWidth: 0.6
                            )
                    )

                // Filled bolt.slash when engaged (loud), outline when not (subdued).
                Image(systemName: isEngaged ? "bolt.slash.fill" : "bolt.slash")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(isEngaged ? engagedAccent : .white.opacity(0.55))
            }
            // Match the 21pt hit-target sizing of the record/cancel/close buttons so it
            // lines up cleanly to the right of Cancel in both the mini bar and the notch.
            .frame(width: 21, height: 21)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isEngaged
            ? "Skip mode processing for this recording is ON — raw transcript (tap to turn off)"
            : "Skip mode processing for this recording (raw transcript)")
        .accessibilityLabel(Text("Skip mode processing for this recording (raw transcript)"))
        .accessibilityValue(Text(isEngaged ? "On" : "Off"))
    }
}

// MARK: - Processing Indicator

struct ProcessingIndicator: View {
    @State private var rotation: Double = 0
    let color: Color

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.9)
            .stroke(color, lineWidth: 1.5)
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - Progress Dot Animation

struct ProgressAnimation: View {
    let color: Color
    let animationSpeed: Double

    private let dotCount = 5
    private let dotSize: CGFloat = 3
    private let dotSpacing: CGFloat = 2

    @State private var currentDot = 0
    @State private var timer: Timer?

    init(color: Color = .white, animationSpeed: Double = 0.3) {
        self.color = color
        self.animationSpeed = animationSpeed
    }

    var body: some View {
        HStack(spacing: dotSpacing) {
            ForEach(0..<dotCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: dotSize / 2)
                    .fill(color.opacity(index <= currentDot ? 0.85 : 0.25))
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .onAppear { startAnimation() }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func startAnimation() {
        timer?.invalidate()
        currentDot = 0
        timer = Timer.scheduledTimer(withTimeInterval: animationSpeed, repeats: true) { _ in
            currentDot = (currentDot + 1) % (dotCount + 2)
            if currentDot > dotCount { currentDot = -1 }
        }
    }
}

// MARK: - Mode Button

struct RecorderModeButton: View {
    @ObservedObject private var modeManager = ModeManager.shared
    let buttonSize: CGFloat
    let padding: EdgeInsets

    @State private var isPopoverPresented = false
    @State private var isHoveringButton: Bool = false
    @State private var isHoveringPopover: Bool = false
    @State private var dismissWorkItem: DispatchWorkItem?

    init(buttonSize: CGFloat = 28, padding: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 7)) {
        self.buttonSize = buttonSize
        self.padding = padding
    }

    var body: some View {
        RecorderToggleButton(
            isEnabled: !modeManager.enabledConfigurations.isEmpty,
            icon: modeManager.enabledConfigurations.isEmpty ? "square.grid.2x2" : (modeManager.currentEffectiveConfiguration?.icon.value ?? "square.grid.2x2"),
            disabled: modeManager.enabledConfigurations.isEmpty
        ) {
            isPopoverPresented.toggle()
        }
        .frame(width: buttonSize)
        .padding(padding)
        .onHover {
            isHoveringButton = $0
            syncPopoverVisibility()
        }
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            ModePopover()
                .onHover {
                    isHoveringPopover = $0
                    syncPopoverVisibility()
                }
        }
    }

    private func syncPopoverVisibility() {
        if isHoveringButton || isHoveringPopover {
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
            isPopoverPresented = true
        } else {
            dismissWorkItem?.cancel()
            let work = DispatchWorkItem { [isPopoverPresentedBinding = $isPopoverPresented] in
                isPopoverPresentedBinding.wrappedValue = false
            }
            dismissWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }
}

// MARK: - Live Transcript View

struct LiveTranscriptView: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .id("bottom")
            }
            .frame(height: 56)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.18),
                        .init(color: .black, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onChange(of: text) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .transaction { $0.disablesAnimations = true }
    }
}

// MARK: - Current App + Paste Destination

/// A short, deliberate confirmation effect for destination actions. The app icon
/// fades up and lands with two restrained beats. Persistent ownership is rendered by
/// the separate locked-destination outline below; the pulse itself always settles.
/// Scale is disabled under Reduce Motion while the useful light confirmation remains.
private struct RecorderIconActionPulseModifier: ViewModifier {
    let trigger: UUID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glowStrength: CGFloat = 0
    @State private var iconScale: CGFloat = 1
    @State private var iconOpacity: Double = 1
    @State private var pulseTask: Task<Void, Never>?

    private let neon = Color(red: 0.20, green: 0.91, blue: 1.00)

    func body(content: Content) -> some View {
        content
            .opacity(iconOpacity)
            .scaleEffect(iconScale)
            .background {
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(neon.opacity(0.22 * Double(glowStrength)))
                    .scaleEffect(1 + (0.52 * glowStrength))
                    .blur(radius: 5)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .stroke(
                        neon.opacity(0.95 * Double(glowStrength)),
                        lineWidth: 0.7 + glowStrength
                    )
                    .scaleEffect(1 + (0.24 * glowStrength))
                    .shadow(
                        color: neon.opacity(0.90 * Double(glowStrength)),
                        radius: 2 + (6 * glowStrength)
                    )
                    .shadow(
                        color: Color.blue.opacity(0.56 * Double(glowStrength)),
                        radius: 5 + (7 * glowStrength)
                    )
                    .allowsHitTesting(false)
            }
            .onChange(of: trigger) {
                guard trigger != nil else { return }
                startPulse()
            }
            .onDisappear {
                pulseTask?.cancel()
                pulseTask = nil
            }
    }

    private func startPulse() {
        pulseTask?.cancel()
        let shouldReduceMotion = reduceMotion

        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            glowStrength = 0
            iconScale = shouldReduceMotion ? 1 : 0.82
            iconOpacity = shouldReduceMotion ? 0.68 : 0.42
        }

        pulseTask = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.16)) {
                glowStrength = shouldReduceMotion ? 0.76 : 1
                iconScale = shouldReduceMotion ? 1 : 1.12
                iconOpacity = 1
            }

            do { try await Task.sleep(nanoseconds: 170_000_000) } catch { return }

            if shouldReduceMotion {
                withAnimation(.easeOut(duration: 0.42)) {
                    glowStrength = 0
                }
                return
            }

            withAnimation(.easeInOut(duration: 0.18)) {
                glowStrength = 0.44
                iconScale = 0.96
            }

            do { try await Task.sleep(nanoseconds: 190_000_000) } catch { return }

            withAnimation(.easeOut(duration: 0.16)) {
                glowStrength = 0.82
                iconScale = 1.07
            }

            do { try await Task.sleep(nanoseconds: 170_000_000) } catch { return }

            withAnimation(.easeOut(duration: 0.42)) {
                glowStrength = 0
                iconScale = 1
                iconOpacity = 1
            }
        }
    }
}

private extension View {
    func recorderIconActionPulse(trigger: UUID?) -> some View {
        modifier(RecorderIconActionPulseModifier(trigger: trigger))
    }
}

private struct RecorderLockedDestinationOutlineModifier: ViewModifier {
    let isLocked: Bool

    private let neon = Color(red: 0.20, green: 0.91, blue: 1.00)

    func body(content: Content) -> some View {
        content
            .overlay {
                if isLocked {
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .stroke(neon.opacity(0.88), lineWidth: 1.35)
                        .shadow(color: neon.opacity(0.48), radius: 3)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.18), value: isLocked)
    }
}

private extension View {
    func recorderLockedDestinationOutline(isLocked: Bool) -> some View {
        modifier(RecorderLockedDestinationOutlineModifier(isLocked: isLocked))
    }
}

struct CurrentFocusApplicationIndicator: View {
    @ObservedObject private var activeWindowService = ActiveWindowService.shared
    let actionPulseID: UUID?
    private let iconSize: CGFloat = 20

    init(actionPulseID: UUID? = nil) {
        self.actionPulseID = actionPulseID
    }

    private var application: NSRunningApplication? {
        if let currentApplication = activeWindowService.currentApplication,
           !currentApplication.isTerminated {
            return currentApplication
        }

        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }
        return frontmostApplication
    }

    private var helpText: String {
        if let application {
            return "Currently focused: \(application.localizedName ?? application.bundleIdentifier ?? String(localized: "Unknown app"))"
        }
        return String(localized: "Currently focused app unavailable")
    }

    var body: some View {
        Group {
            if let application, let applicationIcon = application.icon {
                Image(nsImage: applicationIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous))
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: iconSize, height: iconSize)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous))
            }
        }
        .frame(width: iconSize, height: iconSize)
        .recorderIconActionPulse(trigger: actionPulseID)
        .help(helpText)
        .accessibilityLabel(Text(helpText))
    }
}

struct PasteDestinationIndicator: View {
    enum Context: Equatable {
        case nextTrackStop
        case pendingPaste
    }

    let target: FocusLockService.Target?
    let context: Context
    let actionPulseID: UUID?
    let isLocked: Bool
    private let iconSize: CGFloat = 20

    init(
        target: FocusLockService.Target?,
        context: Context,
        actionPulseID: UUID? = nil,
        isLocked: Bool = false
    ) {
        self.target = target
        self.context = context
        self.actionPulseID = actionPulseID
        self.isLocked = isLocked
    }

    private var helpText: String {
        guard let target else {
            return context == .nextTrackStop
                ? String(localized: "Next Track has no recording-start input — focus an editable input before starting")
                : String(localized: "Pending transcription has no valid paste input")
        }
        switch context {
        case .nextTrackStop:
            return "Next Track → \(target.displayInfo.applicationName) — \(target.displayInfo.inputName)"
        case .pendingPaste:
            return "Pending paste → \(target.displayInfo.applicationName) — \(target.displayInfo.inputName)"
        }
    }

    var body: some View {
        Group {
            if let target, let applicationIcon = target.displayInfo.applicationIcon {
                Image(nsImage: applicationIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous))
            } else if target != nil {
                Image(systemName: "app.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: iconSize, height: iconSize)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous))
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.Status.warningStrong)
                    .frame(width: iconSize, height: iconSize)
                    .background(AppTheme.Status.warningStrong.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous))
            }
        }
        .frame(width: iconSize, height: iconSize)
        .recorderLockedDestinationOutline(isLocked: isLocked && target != nil)
        .recorderIconActionPulse(trigger: actionPulseID)
        .help(helpText)
        .accessibilityLabel(Text(isLocked ? "Locked destination. \(helpText)" : helpText))
    }
}

// MARK: - Recorder Status Display

struct RecorderStatusDisplay: View {
    let currentState: RecordingState
    let audioMeter: AudioMeter
    let menuBarHeight: CGFloat?

    init(currentState: RecordingState, audioMeter: AudioMeter, menuBarHeight: CGFloat? = nil) {
        self.currentState = currentState
        self.audioMeter = audioMeter
        self.menuBarHeight = menuBarHeight
    }

    var body: some View {
        Group {
            if currentState == .enhancing {
                ProcessingStatusDisplay(mode: .enhancing, color: .white).transition(.opacity)
            } else if currentState == .transcribing {
                ProcessingStatusDisplay(mode: .transcribing, color: .white).transition(.opacity)
            } else if currentState == .recording {
                AudioVisualizer(audioMeter: audioMeter, color: .white, isActive: true)
                    .scaleEffect(y: menuBarHeight != nil ? min(1.0, (menuBarHeight! - 8) / 25) : 1.0, anchor: .center)
                    .transition(.opacity)
            } else {
                StaticVisualizer(color: .white)
                    .scaleEffect(y: menuBarHeight != nil ? min(1.0, (menuBarHeight! - 8) / 25) : 1.0, anchor: .center)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: currentState)
    }
}

// MARK: - Assistant Response Panel

struct AssistantPanelView: View {
    @ObservedObject var session: AssistantSession
    let liveFollowUpText: String
    let onSend: (String) -> Void

    @State private var draftMessage = ""
    @FocusState private var isFollowUpFieldFocused: Bool

    private let horizontalPadding: CGFloat = 20
    private let followUpTextColor = Color.white.opacity(0.9)

    private var statusText: String? {
        switch session.phase {
        case .responding, .sendingFollowUp:
            return String(localized: "Thinking")
        case .failed(let message):
            return message
        case .inactive, .ready:
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            messageList
            followUpRow
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 10)
        .frame(height: 320)
        .onAppear(perform: focusFollowUpFieldIfAvailable)
        .onChange(of: session.phase) {
            focusFollowUpFieldIfAvailable()
        }
    }

    private var fullConversationText: String {
        session.messages.map { msg in
            let prefix = msg.role == .user ? "You" : "Assistant"
            return "\(prefix): \(msg.content)"
        }.joined(separator: "\n\n")
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(session.messages) { message in
                        AssistantMessageBubble(message: message)
                            .id(message.id)
                    }

                    if let statusText {
                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.62))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("status")
                    }
                }
                .padding(.vertical, 2)
                .overlay(alignment: .topLeading) {
                    if !session.messages.isEmpty {
                        CopyIconButton(textToCopy: fullConversationText)
                            .scaleEffect(0.72)
                    }
                }
            }
            .onChange(of: session.messages.count) {
                scrollToBottom(proxy)
            }
            .onChange(of: session.phase) {
                scrollToBottom(proxy)
            }
        }
    }

    private var followUpRow: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                if shouldShowLiveFollowUpText {
                    Text(liveFollowUpText)
                        .font(.system(size: 12))
                        .foregroundStyle(followUpTextColor)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .allowsHitTesting(false)
                }

                TextField("", text: $draftMessage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(followUpTextColor)
                    .tint(followUpTextColor)
                    .disabled(!session.canSendFollowUp)
                    .focused($isFollowUpFieldFocused)
                    .onSubmit(sendDraftMessage)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Button(action: sendDraftMessage) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(canSendDraft ? .black : .white.opacity(0.35))
                    .frame(width: 24, height: 24)
                    .background(canSendDraft ? Color.white.opacity(0.88) : Color.white.opacity(0.10))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSendDraft)
            .help("Send follow up")
        }
    }

    private var shouldShowLiveFollowUpText: Bool {
        draftMessage.isEmpty &&
            !liveFollowUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSendDraft: Bool {
        session.canSendFollowUp &&
            !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraftMessage() {
        let trimmed = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.canSendFollowUp, !trimmed.isEmpty else { return }
        draftMessage = ""
        onSend(trimmed)
        focusFollowUpFieldIfAvailable()
    }

    private func focusFollowUpFieldIfAvailable() {
        guard session.canSendFollowUp else { return }
        DispatchQueue.main.async {
            isFollowUpFieldFocused = true
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                if let last = session.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                } else {
                    proxy.scrollTo("status", anchor: .bottom)
                }
            }
        }
    }
}

private struct AssistantMessageBubble: View {
    let message: AssistantDisplayMessage

    private var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        HStack {
            if isUser {
                Spacer(minLength: 36)
            }

            MarkdownContentView(
                message.content,
                fontSize: 12,
                foregroundColor: .white.opacity(isUser ? 0.92 : 0.86),
                alignment: .leading
            )
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(isUser ? Color.white.opacity(0.16) : Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if !isUser {
                        CopyIconButton(textToCopy: message.content)
                            .scaleEffect(0.72)
                            .padding(0)
                    }
                }
                .help(isUser ? message.content : "")

            if !isUser {
                Spacer(minLength: 36)
            }
        }
    }
}

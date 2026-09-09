import AppKit
import ApplicationServices
import Foundation

private let mediaKeySystemDefinedEventTypeRawValue: UInt32 = 14
private let playPauseKeyCode = 16
private let mediaKeySubtype = 8
private let mediaKeyDownState = 0x0A
private let spotifyBundleIdentifier = "com.spotify.client"
private let isHardwareMediaKeyRoutingEnabled = false

private struct YouTubeTabState {
  let tabId: Int
  let title: String
  let url: String
  let playing: Bool
  let updatedAt: Date
}

private final class MenuBarMediaKeyController {
  private var statusItem: NSStatusItem?
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var bridgeHeartbeatTimer: Timer?
  private var spotifyPollingTimer: Timer?
  private var connectedBridgeId: String?
  private var lastBridgeHeartbeatAt: Date?
  private var isAccessibilityTrusted = false
  private var isMediaKeyTapInstalled = false
  private var mediaKeyTapError: String?
  private var lastMediaOwner: MediaOwner?
  private var spotifyState: SpotifyState = .unknown
  private var youtubeTabsById: [Int: YouTubeTabState] = [:]
  private var lastYouTubeTabId: Int?
  private var lastSpotifyActivatedAt: Date?
  private var lastMediaKeyTapRetryAt = Date.distantPast
  private let mediaKeyTapRetryInterval: TimeInterval = 5
  private var isVoiceInkRecordingActive = false
  private var lastRenderedMenuState: [String]?

  // FIX 3 (2026-07-09) — don't DROP a recording start/stop edge that lands while the Chrome bridge is
  // down. The old code just logged a "bridge-down" no-op and lost the edge forever, so a pause/resume
  // that never crossed a downed port could never be recovered (storage rehydration can't help — the
  // edge never arrived at the extension at all). Instead we RETAIN the desired VoiceInk state
  // (isVoiceInkRecordingActive is the source of truth) and set this flag so that when the bridge next
  // reconnects (extension-ready / bridge-ready) we REPLAY the matching directional command exactly once.
  //
  // Why replay-once is safe against the extension's ref-count (and why we deliberately do NOT blindly
  // re-post the notification multiple times): the extension increments dictationDepth on each
  // pause-youtube and decrements on each resume-youtube. We only replay an edge that was dropped while
  // the bridge was DOWN — i.e. one that provably never reached the extension — so replaying it once
  // moves depth by exactly the one step it missed. Re-posting an edge that already landed would
  // double-count; we never do that.
  private var pendingVoiceInkReconcile = false
  // When the bridge is down, a triple-click's playback-preserving stop must remain
  // distinguishable from an ordinary stop. Replaying `resume-youtube` on reconnect
  // would violate the gesture by starting a video that was paused at click three.
  private var pendingVoiceInkPreservePlayback = false

  // Display-only. The tab id the EXTENSION last reported it paused for a dictation (from
  // youtube-pause-result). The extension now OWNS picking + pausing + resuming the right tab (it
  // tracks every tab's most-recently-played state, which the app cannot see), so the app keeps this
  // purely to surface "paused for VoiceInk" in the popup — it drives NO control decisions here.
  // Cleared when a resume result lands. See the rearchitecture note on handleVoiceInkRecordingStarted.
  private var lastDictationPausedTabId: Int?

  func start() {
    // Tag this binary's log lines as "app" and prune the shared log to the 30-day window at launch.
    // The native host owns the recurring daily prune; the app prunes once here so a fresh launch also
    // trims (and so the very first ever run — before any native host exists — still bounds the file).
    logComponent = "app"
    pruneLog()
    setupStatusItem()
    observeBridgeMessages()
    observeVoiceInkRecording()
    observeAgenticMouseYouTubeCommands()
    if isHardwareMediaKeyRoutingEnabled {
      observeAppActivation()
    }
    disableMediaKeyTap() // Hardware media keys are intentionally out of scope now; VoiceInk auto-pause uses notifications only.
    if isHardwareMediaKeyRoutingEnabled {
      startSpotifyPolling()
    }
    startBridgePruning()
    sendStatus("menu-app-started")
  }

  func isPlayPauseKeyDown(_ event: CGEvent) -> Bool {
    guard let nsEvent = NSEvent(cgEvent: event) else {
      return false
    }

    guard nsEvent.subtype.rawValue == mediaKeySubtype else {
      return false
    }

    let keyCode = (nsEvent.data1 & 0xFFFF0000) >> 16
    let keyState = (nsEvent.data1 & 0x0000FF00) >> 8

    return keyCode == playPauseKeyCode && keyState == mediaKeyDownState
  }

  func handlePlayPauseKeyDown() -> Bool {
    guard isHardwareMediaKeyRoutingEnabled else {
      return false
    }

    let targetTabId = currentPlayingYouTubeTargetTabId()
      ?? (lastMediaOwner == .youtube ? currentYouTubeTargetTabId() : nil)

    guard let targetTabId, isBridgeConnected else {
      return false
    }

    var message = BridgeMessage(type: "toggle-youtube")
    message.bridgeId = connectedBridgeId
    message.tabId = targetTabId
    message.reason = "hardware-play-pause"
    message.nativeTimestamp = BridgeNotification.now()
    BridgeNotification.post(message, name: BridgeNotification.appToBridge)
    sendStatus("toggle-youtube-requested")

    return true
  }

  func enableEventTap() {
    guard let eventTap else {
      return
    }

    CGEvent.tapEnable(tap: eventTap, enable: true)
  }

  private var isBridgeConnected: Bool {
    guard let lastBridgeHeartbeatAt else {
      return false
    }

    return Date().timeIntervalSince(lastBridgeHeartbeatAt) < 5
  }

  private static func requestAccessibilityAccess(prompt: Bool) -> Bool {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [promptKey: prompt] as CFDictionary

    return AXIsProcessTrustedWithOptions(options)
  }

  private static func currentSpotifyState() -> SpotifyState {
    let runningSpotifyApps = NSRunningApplication.runningApplications(
      withBundleIdentifier: spotifyBundleIdentifier,
    )

    if runningSpotifyApps.isEmpty {
      return .notRunning
    }

    let process = Process()
    let outputPipe = Pipe()

    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", "tell application \"Spotify\" to player state as string"]
    process.standardOutput = outputPipe
    process.standardError = Pipe()

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      log("Could not run osascript for Spotify state: \(error)")
      return .unknown
    }

    guard process.terminationStatus == 0 else {
      return .unknown
    }

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let rawState = String(data: outputData, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    switch rawState {
      case "playing":
        return .playing
      case "paused":
        return .paused
      case "stopped":
        return .stopped
      case .some:
        return .unknown
      case .none:
        return .unknown
    }
  }

  private func setupStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem?.button?.title = "YS"
    statusItem?.button?.toolTip = "YouTube Spotify Media Key"
    // This status item has no hover behavior. Opting its private status-bar window out of mouse-moved
    // delivery preserves clicks/menu opening while avoiding macOS repeatedly regenerating the
    // Accessibility cursor when the pointer moves across the menu bar.
    statusItem?.button?.window?.acceptsMouseMovedEvents = false
    refreshMenu()
  }

  private func observeBridgeMessages() {
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(handleBridgeNotification(_:)),
      name: BridgeNotification.bridgeToApp,
      object: nil,
    )
  }

  // Observe VoiceInk++'s recording lifecycle notifications (see VoiceInkRecordingNotification in
  // the shared file for the full contract). VoiceInk++ posts these system-wide via
  // DistributedNotificationCenter; we react by pausing/resuming the playing YouTube tab. This is
  // the YouTube-specific complement to VoiceInk++'s own PlaybackController (Spotify/Apple Music/
  // MediaRemote), which can't reliably pause a YouTube tab playing in Chrome.
  private func observeVoiceInkRecording() {
    let center = DistributedNotificationCenter.default()
    center.addObserver(
      self,
      selector: #selector(handleVoiceInkRecordingStarted(_:)),
      name: VoiceInkRecordingNotification.started,
      object: nil,
    )
    center.addObserver(
      self,
      selector: #selector(handleVoiceInkRecordingStopped(_:)),
      name: VoiceInkRecordingNotification.stopped,
      object: nil,
    )
    center.addObserver(
      self,
      selector: #selector(handleVoiceInkRecordingStoppedPreservingPlayback(_:)),
      name: VoiceInkRecordingNotification.stoppedPreservingPlayback,
      object: nil,
    )
    log("Observing VoiceInk notifications started=\(VoiceInkRecordingNotification.started.rawValue) stopped=\(VoiceInkRecordingNotification.stopped.rawValue) stoppedPreservingPlayback=\(VoiceInkRecordingNotification.stoppedPreservingPlayback.rawValue)")
  }

  // Agentic Mouse posts one of two fixed system-wide commands for its top-level YouTube scrub. The
  // app deliberately does not infer a tab here: Chrome's extension has the authoritative PiP,
  // last-focused active-window, audible, active, and playback-recency targeting information.
  private func observeAgenticMouseYouTubeCommands() {
    let center = DistributedNotificationCenter.default()
    center.addObserver(
      self,
      selector: #selector(handleAgenticMouseSeekFiveSeconds(_:)),
      name: AgenticMouseYouTubeNotification.seekBackwardFiveSeconds,
      object: nil,
    )
    center.addObserver(
      self,
      selector: #selector(handleAgenticMouseSeekFiveSeconds(_:)),
      name: AgenticMouseYouTubeNotification.seekForwardFiveSeconds,
      object: nil,
    )
    center.addObserver(
      self,
      selector: #selector(handleAgenticMouseVolumeFivePercent(_:)),
      name: AgenticMouseYouTubeNotification.volumeDecreaseFivePercent,
      object: nil,
    )
    center.addObserver(
      self,
      selector: #selector(handleAgenticMouseVolumeFivePercent(_:)),
      name: AgenticMouseYouTubeNotification.volumeIncreaseFivePercent,
      object: nil,
    )
    center.addObserver(
      self,
      selector: #selector(handleAgenticMouseDoubleSpeedHoldBegan(_:)),
      name: AgenticMouseYouTubeNotification.doubleSpeedHoldBegan,
      object: nil,
    )
    center.addObserver(
      self,
      selector: #selector(handleAgenticMouseDoubleSpeedHoldRenewed(_:)),
      name: AgenticMouseYouTubeNotification.doubleSpeedHoldRenewed,
      object: nil,
    )
    center.addObserver(
      self,
      selector: #selector(handleAgenticMouseDoubleSpeedHoldEnded(_:)),
      name: AgenticMouseYouTubeNotification.doubleSpeedHoldEnded,
      object: nil,
    )
    center.addObserver(
      self,
      selector: #selector(handleAgenticMouseChromeTabHistory(_:)),
      name: AgenticMouseChromeTabHistoryNotification.back,
      object: nil,
    )
    center.addObserver(
      self,
      selector: #selector(handleAgenticMouseChromeTabHistory(_:)),
      name: AgenticMouseChromeTabHistoryNotification.forward,
      object: nil,
    )
    center.addObserver(
      self,
      selector: #selector(handleAgenticMouseChromeWebsite(_:)),
      name: AgenticMouseChromeWebsite.open,
      object: nil,
    )
    log("Observing Agentic Mouse YouTube scrub notifications backward=\(AgenticMouseYouTubeNotification.seekBackwardFiveSeconds.rawValue) forward=\(AgenticMouseYouTubeNotification.seekForwardFiveSeconds.rawValue)")
    log("Observing Agentic Mouse YouTube volume notifications decrease=\(AgenticMouseYouTubeNotification.volumeDecreaseFivePercent.rawValue) increase=\(AgenticMouseYouTubeNotification.volumeIncreaseFivePercent.rawValue)")
    log("Observing Agentic Mouse YouTube 2x hold notifications")
    log("Observing Agentic Mouse Chrome tab-history notifications")
    log("Observing Agentic Mouse Chrome website notification")
  }

  @objc private func handleAgenticMouseChromeTabHistory(_ notification: Notification) {
    guard let direction = AgenticMouseChromeTabHistoryNotification.direction(
      for: notification.name
    ) else {
      log("Ignoring unknown Agentic Mouse Chrome tab-history notification=\(notification.name.rawValue)")
      return
    }
    guard isBridgeConnected else {
      log("Received Chrome tab-history \(direction) while bridge is down — dropping one-shot ratchet")
      sendStatus("agenticmouse-chrome-tab-history-dropped-bridge-down")
      return
    }

    var message = BridgeMessage(type: "navigate-chrome-tab-history")
    message.bridgeId = connectedBridgeId
    message.tabHistoryDirection = direction
    message.reason = "agenticmouse-chrome-tab-history-\(direction)"
    message.nativeTimestamp = BridgeNotification.now()
    BridgeNotification.post(message, name: BridgeNotification.appToBridge)
    sendStatus("agenticmouse-chrome-tab-history-requested")
  }

  @objc private func handleAgenticMouseChromeWebsite(_ notification: Notification) {
    guard let website = AgenticMouseChromeWebsite.decode(notification) else {
      log("Ignoring malformed Agentic Mouse Chrome website notification")
      return
    }
    guard isBridgeConnected else {
      log("Received Chrome website \(website.rawValue) while bridge is down — dropping one-shot request")
      sendStatus("agenticmouse-chrome-website-dropped-bridge-down")
      return
    }

    var message = BridgeMessage(type: "open-chrome-website")
    message.bridgeId = connectedBridgeId
    message.chromeWebsite = website.rawValue
    message.reason = "agenticmouse-chrome-website-\(website.rawValue)"
    message.nativeTimestamp = BridgeNotification.now()
    BridgeNotification.post(message, name: BridgeNotification.appToBridge)
    sendStatus("agenticmouse-chrome-website-requested")
  }

  @objc private func handleAgenticMouseSeekFiveSeconds(_ notification: Notification) {
    guard let seekSeconds = AgenticMouseYouTubeNotification.seekSeconds(for: notification.name) else {
      log("Ignoring unknown Agentic Mouse YouTube seek notification=\(notification.name.rawValue)")
      return
    }
    guard isBridgeConnected else {
      // A seek is intentionally edge-triggered, unlike VoiceInk's durable recording state. Never
      // replay it later: that would rewind a video after the user has moved on.
      log("Received \(notification.name.rawValue) but bridge is down — dropping one-shot scrub ratchet")
      sendStatus("agenticmouse-seek-youtube-dropped-bridge-down")
      return
    }

    var message = BridgeMessage(type: "seek-youtube")
    message.bridgeId = connectedBridgeId
    message.seekSeconds = seekSeconds
    message.reason = seekSeconds > 0
      ? "agenticmouse-seek-forward-five-seconds"
      : "agenticmouse-seek-backward-five-seconds"
    message.nativeTimestamp = BridgeNotification.now()
    BridgeNotification.post(message, name: BridgeNotification.appToBridge)
    sendStatus("agenticmouse-seek-youtube-requested")
  }

  @objc private func handleAgenticMouseVolumeFivePercent(_ notification: Notification) {
    guard let volumeDelta = AgenticMouseYouTubeNotification.volumeDelta(for: notification.name) else {
      log("Ignoring unknown Agentic Mouse YouTube volume notification=\(notification.name.rawValue)")
      return
    }
    guard isBridgeConnected else {
      log("Received \(notification.name.rawValue) but bridge is down — dropping one-shot volume ratchet")
      sendStatus("agenticmouse-volume-youtube-dropped-bridge-down")
      return
    }

    var message = BridgeMessage(type: "adjust-youtube-volume")
    message.bridgeId = connectedBridgeId
    message.volumeDelta = volumeDelta
    message.reason = volumeDelta > 0
      ? "agenticmouse-volume-increase-five-percent"
      : "agenticmouse-volume-decrease-five-percent"
    message.nativeTimestamp = BridgeNotification.now()
    BridgeNotification.post(message, name: BridgeNotification.appToBridge)
    sendStatus("agenticmouse-volume-youtube-requested")
  }

  @objc private func handleAgenticMouseDoubleSpeedHoldBegan(_ notification: Notification) {
    relayAgenticMouseDoubleSpeedHold(notification, type: "begin-youtube-speed-hold")
  }

  @objc private func handleAgenticMouseDoubleSpeedHoldRenewed(_ notification: Notification) {
    relayAgenticMouseDoubleSpeedHold(notification, type: "renew-youtube-speed-hold")
  }

  @objc private func handleAgenticMouseDoubleSpeedHoldEnded(_ notification: Notification) {
    relayAgenticMouseDoubleSpeedHold(notification, type: "end-youtube-speed-hold")
  }

  private func relayAgenticMouseDoubleSpeedHold(_ notification: Notification, type: String) {
    guard let rawToken = notification.userInfo?[AgenticMouseYouTubeNotification.holdTokenKey]
      as? String,
      let token = UUID(uuidString: rawToken)?.uuidString
    else {
      log("Rejected malformed Agentic Mouse YouTube speed-hold token")
      return
    }
    let restorePlaybackRate: Double?
    if let rawRate = notification.userInfo?[AgenticMouseYouTubeNotification.restorePlaybackRateKey] {
      guard type == "end-youtube-speed-hold",
        let rate = rawRate as? Double,
        rate == AgenticMouseYouTubeNotification.normalSpeedValue
      else {
        log("Rejected malformed Agentic Mouse YouTube speed-hold restore rate")
        return
      }
      restorePlaybackRate = rate
    } else {
      restorePlaybackRate = nil
    }
    guard isBridgeConnected else {
      // Start/renew cannot be replayed safely after a physical hold changes.
      // End is also safe to drop because the content-script lease restores
      // the prior playback rate without the bridge.
      log("Received \(notification.name.rawValue) but bridge is down — lease will fail closed")
      sendStatus("agenticmouse-youtube-speed-hold-dropped-bridge-down")
      return
    }

    var message = BridgeMessage(type: type)
    message.bridgeId = connectedBridgeId
    message.holdToken = token
    message.playbackRate = AgenticMouseYouTubeNotification.doubleSpeedValue
    message.holdLeaseMilliseconds = AgenticMouseYouTubeNotification.holdLeaseMilliseconds
    message.restorePlaybackRate = restorePlaybackRate
    message.reason = restorePlaybackRate == nil
      ? "agenticmouse-physical-youtube-speed-hold"
      : "agenticmouse-double-click-youtube-normal-speed"
    message.nativeTimestamp = BridgeNotification.now()
    BridgeNotification.post(message, name: BridgeNotification.appToBridge)
    if type != "renew-youtube-speed-hold" {
      sendStatus("agenticmouse-youtube-speed-hold-\(type)")
    }
  }

  // VoiceInk++ recording STARTED → tell the extension to "pause the dictation target".
  //
  // REARCHITECTURE (Ethan's design): the app no longer tries to work out WHICH YouTube tab to pause.
  // That was the source of the "second dictation paused the wrong tab / nothing" flake — with ~5
  // tabs the app's tab-id tracking got confused. The EXTENSION now owns the decision: it keeps a
  // most-recently-played timestamp per tab and, on this command, pauses the tab that is most-
  // recently-played AND currently playing, remembering it so the matching resume restores exactly
  // it. So here we just relay a directional pause with NO tabId and let the extension pick. The
  // extension recomputes its target fresh on every pause command, so a stale target from a previous
  // (still-transcribing) dictation cannot mislead this one.
  @objc private func handleVoiceInkRecordingStarted(_ notification: Notification) {
    log("Received \(notification.name.rawValue) bridgeConnected=\(isBridgeConnected) — asking extension to pause its most-recently-played target")
    isVoiceInkRecordingActive = true
    pendingVoiceInkPreservePlayback = false

    guard isBridgeConnected else {
      // FIX 3: bridge is down (native host / SW likely suspended). Don't drop the edge — remember that
      // we owe the extension a reconcile and replay it when the bridge comes back (see reconcileVoiceInkStateIfPending).
      pendingVoiceInkReconcile = true
      log("bridge DOWN at recording start — deferring pause; will reconcile on reconnect (pendingReconcile=true)")
      sendStatus("voiceink-record-start-deferred-bridge-down")
      return
    }

    // Bridge is up: this authoritative command supersedes any earlier deferred edge.
    pendingVoiceInkReconcile = false

    var message = BridgeMessage(type: "pause-youtube")
    message.bridgeId = connectedBridgeId
    // Deliberately NO tabId — the extension decides which tab from its live most-recently-played state.
    message.reason = "voiceink-recording-started"
    message.nativeTimestamp = BridgeNotification.now()
    BridgeNotification.post(message, name: BridgeNotification.appToBridge)
    sendStatus("voiceink-pause-youtube-requested")
  }

  // VoiceInk++ recording STOPPED (or cancelled — same at the recorder layer) → tell the extension to
  // "resume the dictation target". The extension resumes EXACTLY the tab it paused for this dictation
  // and clears it; if it paused nothing, the resume is a no-op. No app-side tab bookkeeping needed.
  @objc private func handleVoiceInkRecordingStopped(_ notification: Notification) {
    log("Received \(notification.name.rawValue) bridgeConnected=\(isBridgeConnected) — asking extension to resume its dictation target")
    isVoiceInkRecordingActive = false
    pendingVoiceInkPreservePlayback = false

    guard isBridgeConnected else {
      // FIX 3: bridge down at stop — defer + reconcile on reconnect (same rationale as the start path).
      pendingVoiceInkReconcile = true
      log("bridge DOWN at recording stop — deferring resume; will reconcile on reconnect (pendingReconcile=true)")
      sendStatus("voiceink-record-stop-deferred-bridge-down")
      return
    }

    // Bridge is up: this authoritative command supersedes any earlier deferred edge.
    pendingVoiceInkReconcile = false

    var message = BridgeMessage(type: "resume-youtube")
    message.bridgeId = connectedBridgeId
    // No tabId — the extension resumes exactly the tab it remembered pausing.
    message.reason = "voiceink-recording-stopped"
    message.nativeTimestamp = BridgeNotification.now()
    BridgeNotification.post(message, name: BridgeNotification.appToBridge)
    sendStatus("voiceink-resume-youtube-requested")
  }

  // Primary triple-click ends the recording but must leave current video playback
  // exactly unchanged. Balance the extension's ref-count/target ownership through a
  // dedicated command that never calls the content script's play or pause actions.
  @objc private func handleVoiceInkRecordingStoppedPreservingPlayback(_ notification: Notification) {
    log("Received \(notification.name.rawValue) bridgeConnected=\(isBridgeConnected) — ending dictation ownership without changing playback")
    isVoiceInkRecordingActive = false
    pendingVoiceInkPreservePlayback = true

    guard isBridgeConnected else {
      pendingVoiceInkReconcile = true
      log("bridge DOWN at playback-preserving stop — deferring ownership cleanup without resume")
      sendStatus("voiceink-record-stop-preserve-deferred-bridge-down")
      return
    }

    pendingVoiceInkReconcile = false
    pendingVoiceInkPreservePlayback = false

    var message = BridgeMessage(type: "finish-dictation-preserving-playback")
    message.bridgeId = connectedBridgeId
    message.reason = "voiceink-triple-click-finished"
    message.nativeTimestamp = BridgeNotification.now()
    BridgeNotification.post(message, name: BridgeNotification.appToBridge)
    sendStatus("voiceink-finish-preserving-playback-requested")
  }

  // FIX 3: when the bridge reconnects, replay a start/stop edge that was dropped while it was down.
  // Called from the extension-ready / bridge-ready handlers (both imply the native host is up and the
  // extension is listening again). Sends the ONE directional command that matches our retained desired
  // state (isVoiceInkRecordingActive) and clears the pending flag. Safe against double-counting because
  // we only ever get here for an edge that never reached the extension (bridge was down when it fired).
  private func reconcileVoiceInkStateIfPending() {
    guard pendingVoiceInkReconcile else {
      return
    }

    guard isBridgeConnected else {
      // Reconnect notification arrived but our freshness check still says down — wait for the next one.
      return
    }

    pendingVoiceInkReconcile = false

    let type: String
    let reason: String
    if isVoiceInkRecordingActive {
      type = "pause-youtube"
      reason = "voiceink-reconcile-pause-on-reconnect"
    } else if pendingVoiceInkPreservePlayback {
      type = "finish-dictation-preserving-playback"
      reason = "voiceink-reconcile-finish-preserving-playback-on-reconnect"
    } else {
      type = "resume-youtube"
      reason = "voiceink-reconcile-resume-on-reconnect"
    }
    pendingVoiceInkPreservePlayback = false
    log("RECONCILE on reconnect: replaying \(type) (desiredActive=\(isVoiceInkRecordingActive)) — recovering an edge dropped while the bridge was down")

    var message = BridgeMessage(type: type)
    message.bridgeId = connectedBridgeId
    message.reason = reason
    message.nativeTimestamp = BridgeNotification.now()
    BridgeNotification.post(message, name: BridgeNotification.appToBridge)
    sendStatus("voiceink-\(type)-reconciled")
  }

  private func observeAppActivation() {
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main,
    ) { [weak self] notification in
      guard let self,
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      else {
        return
      }

      guard app.bundleIdentifier == spotifyBundleIdentifier else {
        return
      }

      lastSpotifyActivatedAt = Date()

      if spotifyState == .playing {
        lastMediaOwner = .spotify
        sendStatus("spotify-activated")
      }
    }
  }

  @objc private func handleBridgeNotification(_ notification: Notification) {
    guard let message = BridgeNotification.decode(notification) else {
      return
    }

    switch message.type {
      case "bridge-ready":
        recordBridge(message)
        retryMediaKeyTapAfterPermissionChange()
        reconcileVoiceInkStateIfPending() // FIX 3: replay a start/stop edge dropped while the bridge was down.
        sendStatus("bridge-ready", bridgeId: message.bridgeId)

      case "bridge-heartbeat":
        recordBridge(message)

      case "bridge-disconnected":
        if message.bridgeId == connectedBridgeId {
          connectedBridgeId = nil
          lastBridgeHeartbeatAt = nil
          sendStatus("bridge-disconnected")
        }

      case "extension-ready":
        recordBridge(message)
        retryMediaKeyTapAfterPermissionChange()
        reconcileVoiceInkStateIfPending() // FIX 3: replay a start/stop edge dropped while the bridge was down.
        sendStatus("extension-ready", bridgeId: message.bridgeId)

      case "status-request":
        recordBridge(message)
        retryMediaKeyTapAfterPermissionChange()
        sendStatus("status-request", bridgeId: message.bridgeId)

      case "youtube-state":
        recordBridge(message)
        handleYouTubeState(message)

      case "youtube-pause-result":
        recordBridge(message)
        handleYouTubePauseResult(message)

      case "youtube-resume-result":
        recordBridge(message)
        handleYouTubeResumeResult(message)

      case "youtube-seek-result":
        recordBridge(message)
        handleYouTubeSeekResult(message)

      case "youtube-volume-result":
        recordBridge(message)
        handleYouTubeVolumeResult(message)

      case "youtube-speed-hold-result":
        recordBridge(message)
        handleYouTubeSpeedHoldResult(message)

      case "chrome-website-result":
        recordBridge(message)
        log("Chrome→app chrome-website-result website=\(message.chromeWebsite ?? "nil") opened=\(message.chromeWebsiteOpened.map { String($0) } ?? "nil") tab=\(message.tabId.map { String($0) } ?? "nil") reason=\(message.reason ?? "")")

      case "youtube-tab-closed":
        recordBridge(message)
        handleYouTubeTabClosed(message)

      default:
        log("Ignoring unknown bridge message type: \(message.type)")
    }
  }

  private func recordBridge(_ message: BridgeMessage) {
    guard let bridgeId = message.bridgeId else {
      return
    }

    let wasBridgeConnected = isBridgeConnected
    let previousBridgeId = connectedBridgeId
    connectedBridgeId = bridgeId
    lastBridgeHeartbeatAt = Date()

    // Heartbeats are liveness data, not UI changes. Rebuilding NSMenu for every 2-second heartbeat
    // creates needless AppKit tracking/window churn; refresh only on an actual connection transition.
    if !wasBridgeConnected || previousBridgeId != bridgeId {
      refreshMenu()
    }
  }

  private func startBridgePruning() {
    bridgeHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.pruneBridgeIfStale()
    }
  }

  private func pruneBridgeIfStale() {
    guard connectedBridgeId != nil, !isBridgeConnected else {
      return
    }

    connectedBridgeId = nil
    lastBridgeHeartbeatAt = nil
    sendStatus("bridge-timeout")
  }

  private func startSpotifyPolling() {
    pollSpotify()

    spotifyPollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.pollSpotify()
    }
  }

  private func pollSpotify() {
    let nextSpotifyState = Self.currentSpotifyState()
    let previousSpotifyState = spotifyState
    spotifyState = nextSpotifyState

    if nextSpotifyState == .playing && previousSpotifyState != .playing {
      let youtubeIsPlaying = currentPlayingYouTubeTargetTabId() != nil
      let spotifyWasRecentlyActivated = lastSpotifyActivatedAt.map { Date().timeIntervalSince($0) < 10 } ?? false

      if !youtubeIsPlaying || lastMediaOwner != .youtube || spotifyWasRecentlyActivated {
        lastMediaOwner = .spotify // Spotify only steals from playing YouTube when Spotify was recently activated, otherwise leaked media keys can flip ownership.
      }
    }

    if previousSpotifyState != nextSpotifyState {
      sendStatus("spotify-state-changed")
    }
  }

  private func updateAccessibilityTrust(prompt: Bool) -> Bool {
    isAccessibilityTrusted = Self.requestAccessibilityAccess(prompt: prompt)

    return isAccessibilityTrusted
  }

  private func retryMediaKeyTapAfterPermissionChange() {
    guard isHardwareMediaKeyRoutingEnabled else {
      disableMediaKeyTap()
      return
    }

    if isMediaKeyTapInstalled {
      _ = updateAccessibilityTrust(prompt: false)
      return
    }

    guard Date().timeIntervalSince(lastMediaKeyTapRetryAt) >= mediaKeyTapRetryInterval else {
      return
    }

    lastMediaKeyTapRetryAt = Date()
    installMediaKeyTap(prompt: false) // Re-checks after the user flips the macOS Accessibility switch without requiring an app restart.
  }

  private func installMediaKeyTap(prompt: Bool) {
    guard isHardwareMediaKeyRoutingEnabled else {
      disableMediaKeyTap()
      sendStatus("media-key-tap-disabled")
      return
    }

    let accessibilityTrusted = updateAccessibilityTrust(prompt: prompt)

    let mask = CGEventMask(1 << mediaKeySystemDefinedEventTypeRawValue)
    let controllerPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: mediaKeyEventTapCallback,
      userInfo: controllerPointer,
    )

    guard let tap else {
      isMediaKeyTapInstalled = false
      mediaKeyTapError = accessibilityTrusted
        ? "macOS refused the media-key event tap. Check Input Monitoring for the menu bar app if prompted."
        : "Turn on YouTube Spotify Media Key.app in Accessibility."
      sendStatus("media-key-tap-unavailable")
      log("Could not install media-key event tap for menu bar app. accessibilityTrusted=\(accessibilityTrusted)")
      refreshMenu()
      return
    }

    eventTap = tap
    isMediaKeyTapInstalled = true
    mediaKeyTapError = nil
    runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

    if let runLoopSource {
      CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
    }

    CGEvent.tapEnable(tap: tap, enable: true)
    sendStatus("media-key-tap-installed")
    refreshMenu()
  }

  private func disableMediaKeyTap() {
    isAccessibilityTrusted = false
    isMediaKeyTapInstalled = false
    mediaKeyTapError = "Hardware media-key routing is disabled by design; VoiceInk YouTube auto-pause uses recording notifications instead."
  }

  private func handleYouTubeState(_ message: BridgeMessage) {
    guard let tabId = message.tabId, let playing = message.playing else {
      return
    }

    let tabState = YouTubeTabState(
      tabId: tabId,
      title: message.title ?? "",
      url: message.url ?? "",
      playing: playing,
      updatedAt: Date(),
    )

    let wasPlaying = youtubeTabsById[tabId]?.playing ?? false
    youtubeTabsById[tabId] = tabState
    log("YouTube state tab=\(tabId) playing=\(playing) title=\(tabState.title)")

    if playing {
      lastYouTubeTabId = tabId
    } else if lastYouTubeTabId == nil {
      lastYouTubeTabId = tabId
    }

    let didChangeOwner = playing && lastMediaOwner != .youtube

    if didChangeOwner {
      lastMediaOwner = .youtube
    }

    if playing != wasPlaying || didChangeOwner {
      sendStatus("youtube-state-changed")
    }

    // NB: the app no longer runs any pause/resume/re-pause state machine off YouTube state — the
    // extension owns dictation pause/resume entirely (it sees every tab's real-time play state). We
    // keep tracking youtubeTabsById purely for the menu display + last-media-owner.
  }

  // Pause/resume RESULT handlers. These are now LOG-ONLY (plus a display-state update) — the
  // extension owns the pick + pause + resume, and it recomputes its target fresh on each pause, so
  // the app doesn't need to react to results with any state machine. We keep logging the extension's
  // chosen tab + its lastPlayedAt + why it was chosen so a future "it paused the wrong tab" miss is
  // diagnosable from the single log file.
  private func handleYouTubePauseResult(_ message: BridgeMessage) {
    log("Chrome→app youtube-pause-result paused=\(message.paused.map { String($0) } ?? "nil") tab=\(message.tabId.map { String($0) } ?? "nil") lastPlayedAt=\(message.lastPlayedAt.map { String($0) } ?? "nil") reason=\(message.reason ?? "") — extension chose the tab")

    if message.paused == true {
      lastDictationPausedTabId = message.tabId // Display only (popup "paused for VoiceInk").
      sendStatus("voiceink-pause-youtube-confirmed")
    } else {
      lastDictationPausedTabId = nil
      sendStatus("voiceink-pause-youtube-noop")
    }
  }

  private func handleYouTubeResumeResult(_ message: BridgeMessage) {
    log("Chrome→app youtube-resume-result resumed=\(message.resumed.map { String($0) } ?? "nil") tab=\(message.tabId.map { String($0) } ?? "nil") reason=\(message.reason ?? "") — extension resumed its remembered target")
    lastDictationPausedTabId = nil
    sendStatus(message.resumed == true ? "voiceink-resume-youtube-confirmed" : "voiceink-resume-youtube-noop")
  }

  private func handleYouTubeSeekResult(_ message: BridgeMessage) {
    log("Chrome→app youtube-seek-result sought=\(message.sought.map { String($0) } ?? "nil") tab=\(message.tabId.map { String($0) } ?? "nil") seconds=\(message.seekSeconds.map { String($0) } ?? "nil") reason=\(message.reason ?? "") — extension chose the target")
    sendStatus(message.sought == true ? "agenticmouse-seek-youtube-confirmed" : "agenticmouse-seek-youtube-noop")
  }

  private func handleYouTubeVolumeResult(_ message: BridgeMessage) {
    log("Chrome→app youtube-volume-result adjusted=\(message.volumeAdjusted.map { String($0) } ?? "nil") tab=\(message.tabId.map { String($0) } ?? "nil") delta=\(message.volumeDelta.map { String($0) } ?? "nil") volume=\(message.volume.map { String($0) } ?? "nil") muted=\(message.muted.map { String($0) } ?? "nil") reason=\(message.reason ?? "")")
    sendStatus(message.volumeAdjusted == true
      ? "agenticmouse-volume-youtube-confirmed"
      : "agenticmouse-volume-youtube-noop")
  }

  private func handleYouTubeSpeedHoldResult(_ message: BridgeMessage) {
    log("Chrome→app youtube-speed-hold-result held=\(message.speedHeld.map { String($0) } ?? "nil") tab=\(message.tabId.map { String($0) } ?? "nil") rate=\(message.playbackRate.map { String($0) } ?? "nil") previous=\(message.previousPlaybackRate.map { String($0) } ?? "nil") reason=\(message.reason ?? "")")
    sendStatus(message.speedHeld == true
      ? "agenticmouse-youtube-speed-hold-active"
      : "agenticmouse-youtube-speed-hold-released")
  }

  private func handleYouTubeTabClosed(_ message: BridgeMessage) {
    guard let tabId = message.tabId else {
      return
    }

    youtubeTabsById.removeValue(forKey: tabId)

    // Purely for the popup's "paused for VoiceInk" label — the extension independently drops a closed
    // tab from its own dictation target, so this doesn't affect any resume behavior.
    if lastDictationPausedTabId == tabId {
      lastDictationPausedTabId = nil
    }

    if lastYouTubeTabId == tabId {
      lastYouTubeTabId = youtubeTabsById.values
        .sorted { $0.updatedAt > $1.updatedAt }
        .first?
        .tabId
    }

    sendStatus("youtube-tab-closed")
  }

  private func currentYouTubeTargetTabId() -> Int? {
    if let lastYouTubeTabId, youtubeTabsById[lastYouTubeTabId] != nil {
      return lastYouTubeTabId
    }

    return youtubeTabsById.values
      .sorted { $0.updatedAt > $1.updatedAt }
      .first?
      .tabId
  }

  private func currentPlayingYouTubeTargetTabId() -> Int? {
    if let lastYouTubeTabId, youtubeTabsById[lastYouTubeTabId]?.playing == true {
      return lastYouTubeTabId
    }

    return youtubeTabsById.values
      .filter { $0.playing }
      .sorted { $0.updatedAt > $1.updatedAt }
      .first?
      .tabId
  }

  private func sendStatus(_ messageText: String, bridgeId: String? = nil) {
    var message = BridgeMessage(type: "host-status")
    message.bridgeId = bridgeId ?? connectedBridgeId
    message.lastMediaOwner = lastMediaOwner?.rawValue
    message.spotifyState = spotifyState.rawValue
    message.youtubeTabId = currentYouTubeTargetTabId()
    message.accessibilityTrusted = isAccessibilityTrusted
    message.mediaKeyTapInstalled = isMediaKeyTapInstalled
    message.mediaKeyTapError = mediaKeyTapError
    message.appRunning = true
    message.bridgeConnected = isBridgeConnected
    message.message = messageText
    message.voiceInkRecordingActive = isVoiceInkRecordingActive
    // The extension now owns the pause/resume state machine, so the app has no pending-pause /
    // pending-resume of its own. These fields stay false/nil; only youtubePausedForDictationTabId is
    // populated (display-only) from the extension's last pause result so the popup can still show
    // "paused for VoiceInk".
    message.voiceInkPausePending = false
    message.voiceInkResumePendingTabId = nil
    message.voiceInkResumeAttemptCount = 0
    message.youtubePausedForDictationTabId = lastDictationPausedTabId
    message.nativeTimestamp = BridgeNotification.now()
    log("Status \(messageText) bridgeConnected=\(isBridgeConnected) accessibilityTrusted=\(isAccessibilityTrusted) mediaKeyTapInstalled=\(isMediaKeyTapInstalled) voiceInkActive=\(isVoiceInkRecordingActive) dictationPausedTab=\(lastDictationPausedTabId.map { String($0) } ?? "nil") targetTab=\(currentYouTubeTargetTabId().map { String($0) } ?? "nil") playingTab=\(currentPlayingYouTubeTargetTabId().map { String($0) } ?? "nil")")
    BridgeNotification.post(message, name: BridgeNotification.appToBridge)
    refreshMenu()
  }

  private func refreshMenu() {
    let statusTitle = isHardwareMediaKeyRoutingEnabled
      ? (isMediaKeyTapInstalled ? "Media key tap: installed" : "Media key tap: unavailable")
      : "Hardware media keys: disabled"
    let accessibilityTitle = isHardwareMediaKeyRoutingEnabled
      ? (isAccessibilityTrusted ? "Accessibility: trusted" : "Accessibility: switch is off")
      : "Accessibility: not needed"
    let bridgeTitle = isBridgeConnected ? "Chrome bridge: connected" : "Chrome bridge: waiting"
    let ownerTitle = "Last owner: \(lastMediaOwner?.rawValue ?? "none")"
    let spotifyTitle = "Spotify: \(spotifyState.rawValue)"
    let youtubeTitle = currentYouTubeTargetTabId().map { "YouTube tab: \($0)" } ?? "YouTube tab: none"
    let menuTitles = [statusTitle, accessibilityTitle, bridgeTitle, ownerTitle, spotifyTitle, youtubeTitle]
    let buttonTitle = statusButtonTitle()
    let renderedState = [buttonTitle] + menuTitles

    // sendStatus can be called for diagnostics whose visible state is unchanged. Keep those bridge
    // messages, but avoid replacing the status item's menu unless something the user sees changed.
    guard renderedState != lastRenderedMenuState else {
      return
    }
    lastRenderedMenuState = renderedState
    statusItem?.button?.title = buttonTitle

    let menu = NSMenu()

    for title in menuTitles {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    }

    let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
    quitItem.target = self

    menu.addItem(NSMenuItem.separator())
    menu.addItem(quitItem)
    statusItem?.menu = menu
  }

  private func statusButtonTitle() -> String {
    if isHardwareMediaKeyRoutingEnabled && !isMediaKeyTapInstalled {
      return "YS!"
    }

    switch lastMediaOwner {
      case .some(.youtube):
        return "YT"
      case .some(.spotify):
        return "SP"
      case .none:
        return "YS"
    }
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}

private func mediaKeyEventTapCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  refcon: UnsafeMutableRawPointer?,
) -> Unmanaged<CGEvent>? {
  guard let refcon else {
    return Unmanaged.passUnretained(event)
  }

  let controller = Unmanaged<MenuBarMediaKeyController>
    .fromOpaque(refcon)
    .takeUnretainedValue()

  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    controller.enableEventTap()
    return Unmanaged.passUnretained(event)
  }

  if type.rawValue == mediaKeySystemDefinedEventTypeRawValue,
     controller.isPlayPauseKeyDown(event),
     controller.handlePlayPauseKeyDown()
  {
    return nil
  }

  return Unmanaged.passUnretained(event)
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
  private var controller: MenuBarMediaKeyController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    controller = MenuBarMediaKeyController()
    controller?.start()
  }
}

if CommandLine.arguments.contains("--request-accessibility") {
  print("Hardware media-key routing is disabled; Accessibility is not required for VoiceInk YouTube auto-pause.")
  exit(0)
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()

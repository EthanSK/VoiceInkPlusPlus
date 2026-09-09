import Foundation

private final class NativeBridgeController {
  private let bridgeId = UUID().uuidString
  private let input = FileHandle.standardInput
  private let output = FileHandle.standardOutput
  private let outputLock = NSLock()
  private var heartbeatTimer: Timer?
  private var statusFallbackTimer: Timer?
  private var logPruneTimer: Timer?
  private var lastForwardedStatusAt = Date.distantPast

  func run() {
    // Tag every line this binary writes as native-host (the extension's funnelled lines still carry
    // their own [ext:...] sub-tag inside the message). Also prune the shared log to the 30-day window
    // once at startup so a long-idle machine trims stale lines the moment the bridge comes up.
    logComponent = "native-host"
    pruneLog()
    startLogPruning()
    observeMenuBarApp()
    startInputReader()
    startHeartbeat()
    postBridgeMessage(type: "bridge-ready")
    RunLoop.current.run()
  }

  // Daily self-prune of the shared log. The native host is the always-on process and receives the
  // high-volume extension funnel, so it owns the scheduled prune; log() also prunes opportunistically
  // by write-count so growth is bounded between these daily ticks.
  private func startLogPruning() {
    logPruneTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { _ in
      pruneLog()
    }
  }

  private func observeMenuBarApp() {
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(handleAppNotification(_:)),
      name: BridgeNotification.appToBridge,
      object: nil,
    )
  }

  private func startInputReader() {
    Thread.detachNewThread { [weak self] in
      self?.readLoop()
    }
  }

  private func startHeartbeat() {
    heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      self?.postBridgeMessage(type: "bridge-heartbeat")
    }
  }

  private func readLoop() {
    while true {
      let header = input.readData(ofLength: 4)

      if header.isEmpty {
        postBridgeMessage(type: "bridge-disconnected")
        exit(0)
      }

      guard header.count == 4 else {
        log("Received truncated native messaging header.")
        postBridgeMessage(type: "bridge-disconnected")
        exit(1)
      }

      let messageLength = Self.nativeMessageLength(from: header)
      let messageData = input.readData(ofLength: Int(messageLength))

      guard messageData.count == Int(messageLength) else {
        log("Received truncated native messaging body.")
        postBridgeMessage(type: "bridge-disconnected")
        exit(1)
      }

      do {
        let message = try JSONDecoder().decode(BridgeMessage.self, from: messageData)

        DispatchQueue.main.async { [weak self] in
          self?.handleChromeMessage(message)
        }
      } catch {
        log("Could not decode native message: \(error)")
      }
    }
  }

  private func handleChromeMessage(_ message: BridgeMessage) {
    switch message.type {
      case "extension-ready":
        postBridgeMessage(type: "extension-ready")
        requestMenuBarStatus()

      case "status-request":
        requestMenuBarStatus()

      case "youtube-state":
        postBridgeMessage(message)

      case "youtube-pause-result":
        // Log the raw Chrome pause outcome (paused + reason) as it crosses the bridge. This is a
        // key diagnostic line: `reason` tells us WHY a pause did/did not happen (e.g. "not-playing",
        // "no-youtube-tab-paused", "paused-2-tab(s)") which is otherwise invisible in the menu-bar
        // log. Funnels into the same file as everything else so the whole chain is one timeline.
        log("Chrome→app youtube-pause-result tab=\(message.tabId.map { String($0) } ?? "nil") lastPlayedAt=\(message.lastPlayedAt.map { String($0) } ?? "nil") paused=\(message.paused.map { String($0) } ?? "nil") reason=\(message.reason ?? "")")
        postBridgeMessage(message)

      case "youtube-resume-result":
        log("Chrome→app youtube-resume-result tab=\(message.tabId.map { String($0) } ?? "nil") resumed=\(message.resumed.map { String($0) } ?? "nil") reason=\(message.reason ?? "")")
        postBridgeMessage(message)

      case "youtube-seek-result":
        log("Chrome→app youtube-seek-result tab=\(message.tabId.map { String($0) } ?? "nil") sought=\(message.sought.map { String($0) } ?? "nil") seconds=\(message.seekSeconds.map { String($0) } ?? "nil") reason=\(message.reason ?? "")")
        postBridgeMessage(message)

      case "youtube-volume-result":
        log("Chrome→app youtube-volume-result tab=\(message.tabId.map { String($0) } ?? "nil") adjusted=\(message.volumeAdjusted.map { String($0) } ?? "nil") delta=\(message.volumeDelta.map { String($0) } ?? "nil") volume=\(message.volume.map { String($0) } ?? "nil") muted=\(message.muted.map { String($0) } ?? "nil") reason=\(message.reason ?? "")")
        postBridgeMessage(message)

      case "youtube-speed-hold-result":
        log("Chrome→app youtube-speed-hold-result tab=\(message.tabId.map { String($0) } ?? "nil") held=\(message.speedHeld.map { String($0) } ?? "nil") rate=\(message.playbackRate.map { String($0) } ?? "nil") previous=\(message.previousPlaybackRate.map { String($0) } ?? "nil") reason=\(message.reason ?? "")")
        postBridgeMessage(message)

      case "chrome-tab-history-result":
        log("Chrome→app chrome-tab-history-result direction=\(message.tabHistoryDirection ?? "nil") moved=\(message.tabHistoryMoved.map { String($0) } ?? "nil") tab=\(message.tabId.map { String($0) } ?? "nil") reason=\(message.reason ?? "")")
        postBridgeMessage(message)

      case "chrome-website-result":
        log("Chrome→app chrome-website-result website=\(message.chromeWebsite ?? "nil") opened=\(message.chromeWebsiteOpened.map { String($0) } ?? "nil") tab=\(message.tabId.map { String($0) } ?? "nil") reason=\(message.reason ?? "")")
        postBridgeMessage(message)

      case "youtube-tab-closed":
        postBridgeMessage(message)

      // Persistent log funnel for the Chrome extension (background.js + content-script.js). The
      // extension's own console.* logs are ephemeral (they vanish when the MV3 service worker sleeps
      // or DevTools closes), which made the extension the blind spot for the intermittent
      // "second dictation didn't pause" flake. The extension now ships every meaningful event to the
      // native host as a `client-log` message; we write it into the SAME log file the app uses
      // (~/Library/Logs/youtube-spotify-media-key.log) so app + extension events interleave with
      // timestamps in one tailable file. We deliberately do NOT forward these to the menu-bar app
      // (they're log-only, not bridge control messages).
      case "client-log":
        log("[ext:\(message.reason ?? "?")] \(message.message ?? "")")

      default:
        log("Ignoring unknown Chrome bridge message type: \(message.type)")
    }
  }

  @objc private func handleAppNotification(_ notification: Notification) {
    guard let message = BridgeNotification.decode(notification) else {
      return
    }

    if let messageBridgeId = message.bridgeId, messageBridgeId != bridgeId {
      return
    }

    switch message.type {
      case "host-status":
        lastForwardedStatusAt = Date()
        sendNativeMessage(message)

      case "toggle-youtube":
        sendNativeMessage(message)

      // VoiceInk dictation triggers: the menu bar app emits these directional commands on
      // recording start/stop. They MUST be in this forwarding whitelist or the host silently
      // drops them (the `default: return` below). See background.js / content-script.js for the
      // "pause only if playing / resume only what we paused" contract.
      case "pause-youtube":
        log("app→Chrome pause-youtube tab=\(message.tabId.map { String($0) } ?? "nil") reason=\(message.reason ?? "")")
        sendNativeMessage(message)

      case "resume-youtube":
        log("app→Chrome resume-youtube tab=\(message.tabId.map { String($0) } ?? "nil") reason=\(message.reason ?? "")")
        sendNativeMessage(message)

      // Primary triple-click still has to balance the extension's dictation depth, but it must not
      // turn a video on or off. Keep this as a separate allowlisted command: mapping it to ordinary
      // resume would violate playback preservation, while omitting it would strand bridge ownership.
      case "finish-dictation-preserving-playback":
        log("app→Chrome finish-dictation-preserving-playback reason=\(message.reason ?? "")")
        sendNativeMessage(message)

      case "seek-youtube":
        // This is the fixed-width Agentic Mouse scrub command. The extension selects the YouTube target
        // using the same PiP/active/audible/recency invariants as VoiceInk pause; no Chrome focus or
        // Accessibility interaction is involved.
        log("app→Chrome seek-youtube seconds=\(message.seekSeconds.map { String($0) } ?? "nil") reason=\(message.reason ?? "")")
        sendNativeMessage(message)

      case "adjust-youtube-volume":
        log("app→Chrome adjust-youtube-volume delta=\(message.volumeDelta.map { String($0) } ?? "nil") reason=\(message.reason ?? "")")
        sendNativeMessage(message)

      case "begin-youtube-speed-hold", "renew-youtube-speed-hold", "end-youtube-speed-hold":
        if message.type != "renew-youtube-speed-hold" {
          log("app→Chrome \(message.type) token=\(message.holdToken == nil ? "nil" : "present") rate=\(message.playbackRate.map { String($0) } ?? "nil") restore=\(message.restorePlaybackRate.map { String($0) } ?? "prior") leaseMs=\(message.holdLeaseMilliseconds.map { String($0) } ?? "nil")")
        }
        sendNativeMessage(message)

      case "navigate-chrome-tab-history":
        guard message.tabHistoryDirection == "back" || message.tabHistoryDirection == "forward" else {
          log("Dropped malformed Chrome tab-history direction=\(message.tabHistoryDirection ?? "nil")")
          return
        }
        log("app→Chrome tab-history direction=\(message.tabHistoryDirection ?? "nil")")
        sendNativeMessage(message)

      case "open-chrome-website":
        guard let rawWebsite = message.chromeWebsite,
              AgenticMouseChromeWebsite(rawValue: rawWebsite) != nil
        else {
          log("Dropped malformed Chrome website=\(message.chromeWebsite ?? "nil")")
          return
        }
        log("app→Chrome open website=\(rawWebsite)")
        sendNativeMessage(message)

      default:
        // Previously this was a SILENT drop (`default: return`) — an unwhitelisted app→Chrome
        // command type would vanish with no trace, which is exactly the kind of thing that made the
        // flake hard to diagnose. Log it now so a future dropped command is visible in the file.
        log("Dropped app→bridge message type (not in forwarding whitelist): \(message.type)")
        return
    }
  }

  private func requestMenuBarStatus() {
    let requestedAt = Date()
    postBridgeMessage(type: "status-request")
    statusFallbackTimer?.invalidate()
    statusFallbackTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
      guard let self, lastForwardedStatusAt < requestedAt else {
        return
      }

      sendMenuBarMissingStatus()
    }
  }

  private func sendMenuBarMissingStatus() {
    var message = BridgeMessage(type: "host-status")
    message.bridgeId = bridgeId
    message.spotifyState = SpotifyState.unknown.rawValue
    message.accessibilityTrusted = false
    message.mediaKeyTapInstalled = false
    message.mediaKeyTapError = "Menu bar app is not running. Launch YouTube Spotify Media Key.app."
    message.appRunning = false
    message.bridgeConnected = true
    message.message = "menu-app-not-running"
    message.nativeTimestamp = BridgeNotification.now()
    sendNativeMessage(message)
  }

  private func postBridgeMessage(type: String) {
    var message = BridgeMessage(type: type)
    message.bridgeId = bridgeId
    message.nativeTimestamp = BridgeNotification.now()
    BridgeNotification.post(message, name: BridgeNotification.bridgeToApp)
  }

  private func postBridgeMessage(_ chromeMessage: BridgeMessage) {
    var message = chromeMessage
    message.bridgeId = bridgeId
    message.nativeTimestamp = BridgeNotification.now()
    BridgeNotification.post(message, name: BridgeNotification.bridgeToApp)
  }

  private func sendNativeMessage(_ message: BridgeMessage) {
    do {
      let payload = try JSONEncoder().encode(message)

      guard payload.count <= UInt32.max else {
        log("Native message is too large to send.")
        return
      }

      var length = UInt32(payload.count).littleEndian
      let header = Data(bytes: &length, count: 4)

      outputLock.lock()
      output.write(header)
      output.write(payload)
      outputLock.unlock()
    } catch {
      log("Could not encode native message: \(error)")
    }
  }

  private static func nativeMessageLength(from header: Data) -> UInt32 {
    header.enumerated().reduce(UInt32(0)) { length, byte in
      length | (UInt32(byte.element) << UInt32(byte.offset * 8))
    }
  }
}

@main
private enum NativeBridgeMain {
  static func main() {
    NativeBridgeController().run()
  }
}

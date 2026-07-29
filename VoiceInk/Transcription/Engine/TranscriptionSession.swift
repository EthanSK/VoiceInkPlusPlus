import Foundation
import os

/// Encapsulates a single recording-to-transcription lifecycle (streaming or file-based).
@MainActor
protocol TranscriptionSession: AnyObject {
    /// Prepares the session. Returns an audio chunk callback for streaming, or nil for file-based.
    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)?

    /// Gives a stopped recording a chance to begin provider finalization before
    /// its serial post-processing/delivery turn. File/local sessions deliberately
    /// remain serialized; a realtime cloud session may close its own socket now
    /// while the immutable job identity preserves FIFO delivery later.
    func beginFinalization(audioURL: URL)

    /// Called after recording stops. Returns the final transcribed text.
    func transcribe(audioURL: URL) async throws -> String

    /// Cancel the session and clean up resources.
    func cancel()
}

extension TranscriptionSession {
    func beginFinalization(audioURL _: URL) {}
}

/// Owns exactly one asynchronous final result for exactly one recorded file.
///
/// Rapid recording overlap is safe only when "finish provider A now" and "deliver
/// A in FIFO order later" are separate decisions. This one-shot binding lets a
/// realtime socket close promptly without allowing another recording, audio URL,
/// or later call to replace the result awaited by A's pipeline.
@MainActor
final class TranscriptionFinalizationTask {
    enum FinalizationError: Error, LocalizedError, Equatable {
        case audioIdentityMismatch(expected: String, received: String)

        var errorDescription: String? {
            switch self {
            case .audioIdentityMismatch(let expected, let received):
                return "Streaming finalization audio changed from \(expected) to \(received)."
            }
        }
    }

    typealias Operation = @MainActor (URL) async throws -> String

    private(set) var audioURL: URL?
    private(set) var task: Task<String, Error>?

    @discardableResult
    func begin(audioURL: URL, operation: @escaping Operation) -> Bool {
        let normalizedURL = audioURL.standardizedFileURL
        guard task == nil else {
            return false
        }

        self.audioURL = normalizedURL
        task = Task { @MainActor in
            try Task.checkCancellation()
            let result = try await operation(normalizedURL)
            try Task.checkCancellation()
            return result
        }
        return true
    }

    func value(audioURL: URL, operation: @escaping Operation) async throws -> String {
        let normalizedURL = audioURL.standardizedFileURL
        if task == nil {
            begin(audioURL: normalizedURL, operation: operation)
        }

        guard self.audioURL == normalizedURL, let task else {
            throw FinalizationError.audioIdentityMismatch(
                expected: self.audioURL?.lastPathComponent ?? "unbound",
                received: normalizedURL.lastPathComponent
            )
        }
        return try await task.value
    }

    func cancel() {
        task?.cancel()
    }
}

/// A streaming provider has not produced a deliverable final merely because its
/// commit request returned. In particular, Soniox can acknowledge a very short
/// or still-speaking stop with an empty committed event even though the complete
/// recording file contains speech. Treat that as a request for the existing batch
/// fallback, never as text to send through Primary or either Next-button route.
enum StreamingFinalTextDisposition: Equatable {
    case deliver(String)
    case useBatchFallback

    static func resolve(_ text: String) -> Self {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .useBatchFallback
            : .deliver(text)
    }
}

// MARK: - File-Based Session

/// File-based session: records to file, uploads after stop.
@MainActor
final class FileTranscriptionSession: TranscriptionSession {
    private let service: TranscriptionService
    private var model: (any TranscriptionModel)?
    private var context: TranscriptionRequestContext = .currentDefaults

    init(service: TranscriptionService) {
        self.service = service
    }

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? {
        self.model = configuration.model
        self.context = configuration.requestContext
        return nil
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let model = model else {
            throw VoiceInkEngineError.transcriptionFailed
        }
        return try await service.transcribe(audioURL: audioURL, model: model, context: context)
    }

    func cancel() {
        // No-op for file-based transcription
    }
}

// MARK: - Streaming Session

/// Streaming session with automatic fallback to file-based upload on failure.
@MainActor
final class StreamingTranscriptionSession: TranscriptionSession {
    private let streamingService: StreamingTranscriptionService
    private let fallbackService: TranscriptionService
    private let finalization = TranscriptionFinalizationTask()
    private var model: (any TranscriptionModel)?
    private var context: TranscriptionRequestContext = .currentDefaults
    private var streamingFailed = false
    private var eagerlyFinalizesAfterStop = false
    private var startupTask: Task<Void, Never>?
    private var startupTaskID: UUID?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "StreamingTranscriptionSession")

    init(streamingService: StreamingTranscriptionService, fallbackService: TranscriptionService) {
        self.streamingService = streamingService
        self.fallbackService = fallbackService
    }

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? {
        let model = configuration.model
        let context = configuration.requestContext

        self.model = model
        self.context = context
        // AssemblyAI limits concurrent realtime sockets, while OpenAI must commit the
        // exact live audio turn before a later recorder can make its own partials look
        // current. Both therefore close promptly at stop instead of waiting behind an
        // older job's formatting, enhancement, or destination delivery. The immutable
        // finalization task still preserves FIFO delivery and exact audio identity.
        eagerlyFinalizesAfterStop = model.provider == .assemblyAI || model.provider == .openAI
        logger.notice("Streaming session prepare model=\(model.displayName, privacy: .public)")

        // Return callback immediately; WebSocket connects in background
        let service = streamingService
        let callback: (Data) -> Void = { [weak service] data in
            service?.sendAudioChunk(data)
        }

        startupTask?.cancel()
        let taskID = UUID()
        startupTaskID = taskID
        startupTask = Task { [weak self] in
            guard let self = self else { return }
            defer {
                if self.startupTaskID == taskID {
                    self.startupTask = nil
                    self.startupTaskID = nil
                }
            }
            guard !Task.isCancelled else { return }

            do {
                let start = Date()
                try await self.streamingService.startStreaming(model: model, context: context)
                guard !Task.isCancelled else {
                    self.streamingService.cancel()
                    return
                }
                self.logger.notice("Streaming session connected model=\(model.displayName, privacy: .public) elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s")
            } catch is CancellationError {
                self.streamingService.cancel()
            } catch {
                guard !Task.isCancelled else { return }
                let desc = error.localizedDescription
                self.logger.error("❌ Failed to start streaming, will fall back to batch: \(desc, privacy: .public)")
                self.streamingFailed = true
            }
        }

        return callback
    }

    func beginFinalization(audioURL: URL) {
        guard eagerlyFinalizesAfterStop else { return }
        let didBegin = finalization.begin(audioURL: audioURL) { [weak self] boundAudioURL in
            guard let self else {
                throw VoiceInkEngineError.transcriptionFailed
            }
            return try await self.performTranscription(audioURL: boundAudioURL)
        }
        if didBegin {
            logger.notice("Streaming finalization started at recording stop file=\(audioURL.lastPathComponent, privacy: .public)")
        }
    }

    func transcribe(audioURL: URL) async throws -> String {
        try await finalization.value(audioURL: audioURL) { [weak self] boundAudioURL in
            guard let self else {
                throw VoiceInkEngineError.transcriptionFailed
            }
            return try await self.performTranscription(audioURL: boundAudioURL)
        }
    }

    private func performTranscription(audioURL: URL) async throws -> String {
        guard let model = model else {
            throw VoiceInkEngineError.transcriptionFailed
        }

        // A very short recording can stop before the background WebSocket handshake
        // finishes. Await that exact session's startup result before deciding whether
        // to commit or use its completed WAV fallback; otherwise `notConnected` races
        // a connection that was about to become usable.
        if let startupTask {
            await startupTask.value
        }
        try Task.checkCancellation()

        if !streamingFailed {
            do {
                let start = Date()
                logger.notice("Streaming stop/transcribe started model=\(model.displayName, privacy: .public)")
                let text = try await streamingService.stopAndGetFinalText()
                switch StreamingFinalTextDisposition.resolve(text) {
                case .deliver(let finalText):
                    logger.notice("Streaming transcript received elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s chars=\(finalText.count, privacy: .public)")
                    return finalText
                case .useBatchFallback:
                    // Realtime partials are HUD preview only. An empty commit must
                    // not become a blank paste or skip the user's configured Return;
                    // finish the same audio through the normal provider first.
                    logger.warning("Streaming finalized without usable text; falling back to completed-file transcription")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.error("❌ Streaming failed, falling back to batch: \(error, privacy: .public)")
                streamingService.cancel()
            }
        } else {
            streamingService.cancel()
        }

        try Task.checkCancellation()
        let fallbackStart = Date()
        logger.notice("Using batch fallback for \(model.displayName, privacy: .public) file=\(audioURL.lastPathComponent, privacy: .public)")
        let text = try await fallbackService.transcribe(audioURL: audioURL, model: model, context: context)
        try Task.checkCancellation()
        logger.notice("Batch fallback completed elapsed=\(Date().timeIntervalSince(fallbackStart), format: .fixed(precision: 3), privacy: .public)s chars=\(text.count, privacy: .public)")
        return text
    }

    func cancel() {
        finalization.cancel()
        startupTask?.cancel()
        startupTask = nil
        startupTaskID = nil
        streamingService.cancel()
    }
}

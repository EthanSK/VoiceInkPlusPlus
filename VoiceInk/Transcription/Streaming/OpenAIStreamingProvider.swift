import Foundation
import SwiftData

/// Incremental 16 kHz PCM16 to 24 kHz PCM16 conversion for OpenAI Realtime.
/// The phase and preceding sample survive audio callback boundaries so chunking cannot
/// introduce discontinuities or subtly change the submitted recording.
struct OpenAIRealtimePCMResampler {
    private var inputSamples: [Int16] = []
    private var nextSourcePosition = 0.0
    private var pendingByte: UInt8?

    mutating func convert(_ data: Data) -> Data {
        appendSamples(from: data)
        return makeOutput(flushing: false)
    }

    mutating func flush() -> Data {
        guard !inputSamples.isEmpty else {
            pendingByte = nil
            return Data()
        }
        return makeOutput(flushing: true)
    }

    private mutating func appendSamples(from data: Data) {
        var bytes = Array(data)
        if let pendingByte {
            bytes.insert(pendingByte, at: 0)
            self.pendingByte = nil
        }
        if bytes.count.isMultiple(of: 2) == false {
            pendingByte = bytes.removeLast()
        }

        var index = 0
        while index + 1 < bytes.count {
            let bits = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            inputSamples.append(Int16(bitPattern: bits))
            index += 2
        }
    }

    private mutating func makeOutput(flushing: Bool) -> Data {
        if flushing, let last = inputSamples.last {
            inputSamples.append(last)
        }

        var output: [Int16] = []
        output.reserveCapacity(Int(Double(inputSamples.count) * 1.5) + 2)

        while nextSourcePosition + 1 < Double(inputSamples.count) {
            let lowerIndex = Int(nextSourcePosition)
            let fraction = nextSourcePosition - Double(lowerIndex)
            let lower = Double(inputSamples[lowerIndex])
            let upper = Double(inputSamples[lowerIndex + 1])
            let interpolated = lower + ((upper - lower) * fraction)
            output.append(Int16(clamping: Int(interpolated.rounded())))
            nextSourcePosition += 2.0 / 3.0
        }

        if flushing {
            inputSamples.removeAll(keepingCapacity: false)
            nextSourcePosition = 0
            pendingByte = nil
        } else {
            let removable = min(Int(nextSourcePosition), max(0, inputSamples.count - 1))
            if removable > 0 {
                inputSamples.removeFirst(removable)
                nextSourcePosition -= Double(removable)
            }
        }

        var data = Data(capacity: output.count * MemoryLayout<Int16>.size)
        for sample in output {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

/// Dedicated WebSocket adapter for OpenAI's transcription session. Realtime deltas remain
/// recorder-HUD preview only; only the completed event enters the existing one-shot final
/// delivery pipeline selected by Primary or Next.
final class OpenAIStreamingProvider: ContextualStreamingTranscriptionProvider, @unchecked Sendable {
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?
    private var partialsByItemID: [String: String] = [:]
    private var resampler = OpenAIRealtimePCMResampler()
    private let modelContext: ModelContext
    private let stateLock = NSLock()
    private var didCommitStorage = false
    private var didSignalFinalStorage = false

    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        var continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        transcriptionEvents = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

    deinit {
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        urlSession?.invalidateAndCancel()
        eventsContinuation?.finish()
    }

    func connect(
        model: any TranscriptionModel,
        language: String?,
        context: TranscriptionRequestContext
    ) async throws {
        guard model.name == OpenAITranscriptionConfiguration.liveModelName else {
            throw StreamingTranscriptionError.serverError(
                "Unsupported OpenAI streaming model: \(model.name)"
            )
        }
        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "OpenAI"),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StreamingTranscriptionError.missingAPIKey
        }

        // Transcription sessions use an intent-scoped Realtime connection. Putting
        // gpt-live-transcribe in the URL makes it the session model and is rejected;
        // the model belongs only in audio.input.transcription.model below.
        let url = OpenAITranscriptionConfiguration.realtimeWebSocketURL

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        urlSession = session
        webSocketTask = task
        partialsByItemID.removeAll(keepingCapacity: true)
        resampler = OpenAIRealtimePCMResampler()
        setDidCommit(false)
        resetFinalSignal()
        task.resume()

        let sessionUpdate = OpenAITranscriptionConfiguration.realtimeSessionUpdate(
            language: language,
            prompt: context.prompt,
            customVocabulary: customDictionaryTerms()
        )
        try await sendJSON(sessionUpdate, over: task)
        try await waitForSessionReady(from: task)

        eventsContinuation?.yield(.sessionStarted)
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func sendAudioChunk(_ data: Data) async throws {
        guard let task = webSocketTask else {
            throw StreamingTranscriptionError.notConnected
        }
        let converted = resampler.convert(data)
        guard !converted.isEmpty else { return }
        try await sendAudio(converted, over: task)
    }

    func commit() async throws {
        guard let task = webSocketTask else {
            throw StreamingTranscriptionError.notConnected
        }

        let tail = resampler.flush()
        if !tail.isEmpty {
            try await sendAudio(tail, over: task)
        }
        setDidCommit(true)
        try await sendJSON(["type": "input_audio_buffer.commit"], over: task)
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        partialsByItemID.removeAll(keepingCapacity: false)
        setDidCommit(false)
        resetFinalSignal()
        eventsContinuation?.finish()
    }

    private func waitForSessionReady(from task: URLSessionWebSocketTask) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw StreamingTranscriptionError.connectionFailed("OpenAI provider was released")
                }
                while true {
                    let message: URLSessionWebSocketTask.Message
                    do {
                        message = try await task.receive()
                    } catch {
                        throw StreamingTranscriptionError.connectionFailed(error.localizedDescription)
                    }
                    guard let json = self.decodeMessage(message) else { continue }

                    switch json["type"] as? String {
                    case "session.updated":
                        return
                    case "error":
                        throw StreamingTranscriptionError.serverError(self.errorMessage(from: json))
                    default:
                        continue
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw StreamingTranscriptionError.timeout
            }

            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func receiveLoop() async {
        guard let task = webSocketTask else { return }

        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                if let json = decodeMessage(message) {
                    handleMessage(json)
                }
            } catch {
                if !Task.isCancelled {
                    eventsContinuation?.yield(
                        .error(StreamingTranscriptionError.connectionFailed(error.localizedDescription))
                    )
                    signalEmptyFinalAfterCommitIfNeeded()
                }
                break
            }
        }
    }

    private func handleMessage(_ json: [String: Any]) {
        switch json["type"] as? String {
        case "conversation.item.input_audio_transcription.delta":
            guard let delta = json["delta"] as? String, !delta.isEmpty else { return }
            let itemID = (json["item_id"] as? String) ?? "active"
            let cumulative = partialsByItemID[itemID, default: ""] + delta
            partialsByItemID[itemID] = cumulative
            eventsContinuation?.yield(.partial(text: cumulative))

        case "conversation.item.input_audio_transcription.completed":
            let itemID = (json["item_id"] as? String) ?? "active"
            let final = (json["transcript"] as? String) ?? partialsByItemID[itemID, default: ""]
            partialsByItemID[itemID] = nil
            yieldFinalOnce(final)

        case "conversation.item.input_audio_transcription.failed", "error":
            eventsContinuation?.yield(
                .error(StreamingTranscriptionError.serverError(errorMessage(from: json)))
            )
            signalEmptyFinalAfterCommitIfNeeded()

        default:
            break
        }
    }

    private func signalEmptyFinalAfterCommitIfNeeded() {
        if didCommit {
            yieldFinalOnce("")
        }
    }

    private func yieldFinalOnce(_ text: String) {
        stateLock.lock()
        let shouldYield = !didSignalFinalStorage
        didSignalFinalStorage = true
        stateLock.unlock()
        if shouldYield {
            eventsContinuation?.yield(.committed(text: text))
        }
    }

    private func sendAudio(_ data: Data, over task: URLSessionWebSocketTask) async throws {
        try await sendJSON(
            [
                "type": "input_audio_buffer.append",
                "audio": data.base64EncodedString(),
            ],
            over: task
        )
    }

    private func sendJSON(_ object: [String: Any], over task: URLSessionWebSocketTask) async throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw StreamingTranscriptionError.serverError("Invalid OpenAI Realtime request")
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw StreamingTranscriptionError.serverError("Could not encode OpenAI Realtime request")
        }
        do {
            try await task.send(.string(text))
        } catch {
            throw StreamingTranscriptionError.connectionFailed(error.localizedDescription)
        }
    }

    private func decodeMessage(_ message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        let data: Data
        switch message {
        case .string(let text):
            guard let textData = text.data(using: .utf8) else { return nil }
            data = textData
        case .data(let binaryData):
            data = binaryData
        @unknown default:
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func errorMessage(from json: [String: Any]) -> String {
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        if let message = json["message"] as? String {
            return message
        }
        return "OpenAI Realtime transcription failed"
    }

    private func customDictionaryTerms() -> [String] {
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\.word)])
        guard let vocabularyWords = try? modelContext.fetch(descriptor) else {
            return []
        }
        return vocabularyWords.map(\.word)
    }

    private var didCommit: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return didCommitStorage
    }

    private func setDidCommit(_ value: Bool) {
        stateLock.lock()
        didCommitStorage = value
        stateLock.unlock()
    }

    private func resetFinalSignal() {
        stateLock.lock()
        didSignalFinalStorage = false
        stateLock.unlock()
    }
}

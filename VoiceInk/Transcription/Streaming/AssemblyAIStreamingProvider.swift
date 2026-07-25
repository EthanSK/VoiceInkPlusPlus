import Foundation
import SwiftData

/// Connection parameters for AssemblyAI streaming.
///
/// Universal-3.5 Pro's quality preset is part of the WebSocket handshake, so it
/// cannot be represented by the model name alone. Keep the full contract here
/// instead of relying on LLMkit's older balanced-mode adapter.
enum AssemblyAIStreamingConnectionConfiguration {
    static let universal35ProModelName = "universal-3-5-pro"
    static let maxAccuracyMode = "max_accuracy"

    private static let keytermLimit = 100

    static func connectionURL(
        modelName: String,
        language: String?,
        prompt: String?,
        customVocabulary: [String]
    ) -> URL? {
        var components = URLComponents(string: "wss://streaming.assemblyai.com/v3/ws")
        var queryItems = [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
        ]

        if modelName == universal35ProModelName {
            queryItems.append(contentsOf: [
                URLQueryItem(name: "speech_model", value: universal35ProModelName),
                URLQueryItem(name: "mode", value: maxAccuracyMode),
            ])

            if let languageCodes = languageCodesJSON(language) {
                queryItems.append(URLQueryItem(name: "language_codes", value: languageCodes))
            }

            let trimmedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedPrompt.isEmpty {
                queryItems.append(URLQueryItem(name: "prompt", value: trimmedPrompt))
            }
        } else if modelName == "universal-streaming" {
            let resolvedModel = language == "en"
                ? "universal-streaming-english"
                : "universal-streaming-multilingual"
            queryItems.append(contentsOf: [
                URLQueryItem(name: "speech_model", value: resolvedModel),
                URLQueryItem(name: "format_turns", value: "true"),
                URLQueryItem(name: "end_of_turn_confidence_threshold", value: "0.75"),
                URLQueryItem(name: "min_turn_silence", value: "2000"),
                URLQueryItem(name: "max_turn_silence", value: "5000"),
            ])
            if (language == nil || language == "auto"),
               resolvedModel == "universal-streaming-multilingual" {
                queryItems.append(URLQueryItem(name: "language_detection", value: "true"))
            }
        } else {
            return nil
        }

        let keyterms = normalizedKeyterms(customVocabulary)
        if let keytermsJSON = jsonArrayString(keyterms), !keyterms.isEmpty {
            queryItems.append(URLQueryItem(name: "keyterms_prompt", value: keytermsJSON))
        }

        components?.queryItems = queryItems
        return components?.url
    }

    private static func languageCodesJSON(_ language: String?) -> String? {
        guard let language,
              !language.isEmpty,
              language != "auto" else {
            return nil
        }
        return jsonArrayString([language])
    }

    private static func normalizedKeyterms(_ customVocabulary: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for term in customVocabulary {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let wordCount = trimmed.split(separator: " ").count
            guard !trimmed.isEmpty, trimmed.count <= 50, wordCount <= 6 else { continue }

            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
            if result.count == keytermLimit { break }
        }

        return result
    }

    private static func jsonArrayString(_ values: [String]) -> String? {
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}

/// AssemblyAI streaming provider.
///
/// Universal-3.5 Pro is intentionally implemented directly here because the
/// pinned LLMkit client still identifies the previous model and cannot request
/// `max_accuracy`, `language_codes`, contextual prompting, and Vocabulary as one
/// verified connection contract.
final class AssemblyAIStreamingProvider: StreamingTranscriptionProvider, @unchecked Sendable {
    private static let minimumChunkBytes = 1_600

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var pendingAudio = Data()
    private var lastCommittedTurnOrder: Int?
    private var didSendTerminate = false
    private let modelContext: ModelContext

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

    func connect(model: any TranscriptionModel, language: String?) async throws {
        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "AssemblyAI"),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StreamingTranscriptionError.missingAPIKey
        }

        guard let url = AssemblyAIStreamingConnectionConfiguration.connectionURL(
            modelName: model.name,
            language: language,
            prompt: transcriptionPrompt(),
            customVocabulary: customDictionaryTerms()
        ) else {
            throw StreamingTranscriptionError.serverError(
                "Unsupported AssemblyAI streaming model: \(model.name)"
            )
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        urlSession = session
        webSocketTask = task
        pendingAudio.removeAll(keepingCapacity: true)
        lastCommittedTurnOrder = nil
        didSendTerminate = false
        task.resume()

        try await waitForBeginEvent(from: task)
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func sendAudioChunk(_ data: Data) async throws {
        guard let task = webSocketTask else {
            throw StreamingTranscriptionError.notConnected
        }

        pendingAudio.append(data)
        while pendingAudio.count >= Self.minimumChunkBytes {
            let chunk = pendingAudio.prefix(Self.minimumChunkBytes)
            try await task.send(.data(Data(chunk)))
            pendingAudio.removeFirst(Self.minimumChunkBytes)
        }
    }

    func commit() async throws {
        guard let task = webSocketTask else {
            throw StreamingTranscriptionError.notConnected
        }

        if !pendingAudio.isEmpty {
            try await task.send(.data(pendingAudio))
            pendingAudio.removeAll(keepingCapacity: true)
        }

        didSendTerminate = true
        try await task.send(.string(#"{"type":"Terminate"}"#))
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil

        if let task = webSocketTask {
            if !didSendTerminate {
                try? await task.send(.string(#"{"type":"Terminate"}"#))
            }
            task.cancel(with: .normalClosure, reason: nil)
        }

        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        eventsContinuation?.finish()
        pendingAudio.removeAll(keepingCapacity: false)
        lastCommittedTurnOrder = nil
        didSendTerminate = false
    }

    private func waitForBeginEvent(from task: URLSessionWebSocketTask) async throws {
        do {
            while true {
                let message = try await task.receive()
                guard let json = decodeMessage(message) else { continue }

                if let error = json["error"] as? String {
                    throw StreamingTranscriptionError.serverError(error)
                }

                if json["type"] as? String == "Begin" {
                    eventsContinuation?.yield(.sessionStarted)
                    return
                }

                handleMessage(json)
            }
        } catch let error as StreamingTranscriptionError {
            throw error
        } catch {
            throw StreamingTranscriptionError.connectionFailed(error.localizedDescription)
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
                }
                break
            }
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

    private func handleMessage(_ json: [String: Any]) {
        if let error = json["error"] as? String {
            eventsContinuation?.yield(.error(StreamingTranscriptionError.serverError(error)))
            return
        }

        switch json["type"] as? String {
        case "Turn":
            handleTurn(json)
        case "Termination":
            // Signal completion even when the last audio produced no new turn.
            eventsContinuation?.yield(.committed(text: ""))
        default:
            break
        }
    }

    private func handleTurn(_ json: [String: Any]) {
        let transcript = (json["transcript"] as? String) ?? ""
        guard !transcript.isEmpty else { return }

        let endOfTurn = (json["end_of_turn"] as? Bool) ?? false
        let turnOrder = json["turn_order"] as? Int

        if endOfTurn, lastCommittedTurnOrder != turnOrder {
            eventsContinuation?.yield(.committed(text: transcript))
            lastCommittedTurnOrder = turnOrder
        } else if !endOfTurn {
            eventsContinuation?.yield(.partial(text: transcript))
        }
    }

    private func transcriptionPrompt() -> String? {
        let prompt = UserDefaults.standard.string(forKey: "TranscriptionPrompt") ?? ""
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func customDictionaryTerms() -> [String] {
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\.word)])
        guard let vocabularyWords = try? modelContext.fetch(descriptor) else {
            return []
        }

        var seen = Set<String>()
        return vocabularyWords.compactMap { vocabularyWord in
            let trimmed = vocabularyWord.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }
}

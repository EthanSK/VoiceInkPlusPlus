import Foundation
import SwiftData
import LLMkit

/// OpenAI's continuously streaming transcription model plus its completed-audio fallback.
/// `gpt-live-transcribe` itself is Realtime-only, so an empty/failed live session uploads the
/// same immutable WAV to `gpt-transcribe` rather than pretending the live model is a file model.
struct OpenAIProvider: CloudProvider {
    let modelProvider: ModelProvider = .openAI
    let providerKey = "OpenAI"
    let languageCodes: [String]? = nil
    let includesAutoDetect = true
    let isStreamingOnly = true

    var models: [CloudModel] {[
        CloudModel(
            name: OpenAITranscriptionConfiguration.liveModelName,
            displayName: "GPT Live Transcribe",
            description: "OpenAI's accuracy-first live transcription with xhigh context delay, English hints, and VoiceInk Vocabulary keywords.",
            provider: .openAI,
            speed: 0.92,
            accuracy: 0.98,
            isMultilingual: true,
            supportsStreaming: true,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .openAI)
        )
    ]}

    func transcribe(
        audioData: Data,
        fileName: String,
        apiKey: String,
        model _: String,
        language: String?,
        prompt: String?,
        customVocabulary: [String]
    ) async throws -> String {
        try await OpenAICompletedAudioTranscriber.transcribe(
            audioData: audioData,
            fileName: fileName,
            apiKey: apiKey,
            language: language,
            prompt: prompt,
            customVocabulary: customVocabulary
        )
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? {
        OpenAIStreamingProvider(modelContext: modelContext)
    }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        await OpenAITranscriptionClient.verifyAPIKey(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: key
        )
    }
}

enum OpenAITranscriptionConfiguration {
    static let liveModelName = "gpt-live-transcribe"
    static let completedAudioModelName = "gpt-transcribe"
    static let accuracyDelay = "xhigh"
    static let realtimeSampleRate = 24_000

    private static let keywordLimit = 100
    private static let promptCharacterLimit = 4_096

    static func normalizedPrompt(_ prompt: String?) -> String? {
        let trimmed = (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(promptCharacterLimit))
    }

    static func normalizedKeywords(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.contains("<"),
                  !trimmed.contains(">"),
                  !trimmed.contains("\r"),
                  !trimmed.contains("\n") else {
                continue
            }

            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
            if result.count == keywordLimit { break }
        }

        return result
    }

    static func normalizedLanguages(_ language: String?) -> [String] {
        guard let language,
              !language.isEmpty,
              language != "auto" else {
            return []
        }
        return [language]
    }

    static func realtimeSessionUpdate(
        language: String?,
        prompt: String?,
        customVocabulary: [String]
    ) -> [String: Any] {
        var transcription: [String: Any] = [
            "model": liveModelName,
            "delay": accuracyDelay,
        ]

        if let prompt = normalizedPrompt(prompt) {
            transcription["prompt"] = prompt
        }

        let keywords = normalizedKeywords(customVocabulary)
        if !keywords.isEmpty {
            transcription["keywords"] = keywords
        }

        let languages = normalizedLanguages(language)
        if !languages.isEmpty {
            transcription["languages"] = languages
        }

        return [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": realtimeSampleRate,
                        ],
                        "transcription": transcription,
                        "turn_detection": NSNull(),
                    ],
                ],
            ],
        ]
    }

    static func completedAudioFields(
        language: String?,
        prompt: String?,
        customVocabulary: [String]
    ) -> [(name: String, value: String)] {
        var fields: [(String, String)] = [
            ("model", completedAudioModelName),
            ("response_format", "json"),
        ]

        if let prompt = normalizedPrompt(prompt) {
            fields.append(("prompt", prompt))
        }
        for language in normalizedLanguages(language) {
            fields.append(("languages[]", language))
        }
        for keyword in normalizedKeywords(customVocabulary) {
            fields.append(("keywords[]", keyword))
        }
        return fields
    }
}

private enum OpenAICompletedAudioTranscriber {
    private struct Response: Decodable {
        let text: String
    }

    static func transcribe(
        audioData: Data,
        fileName: String,
        apiKey: String,
        language: String?,
        prompt: String?,
        customVocabulary: [String]
    ) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudTranscriptionError.missingAPIKey
        }

        let boundary = "VoiceInkOpenAI-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let body = multipartBody(
            audioData: audioData,
            fileName: fileName,
            boundary: boundary,
            fields: OpenAITranscriptionConfiguration.completedAudioFields(
                language: language,
                prompt: prompt,
                customVocabulary: customVocabulary
            )
        )

        do {
            let (data, response) = try await URLSession.shared.upload(for: request, from: body)
            guard let http = response as? HTTPURLResponse else {
                throw CloudTranscriptionError.networkError(URLError(.badServerResponse))
            }
            guard (200..<300).contains(http.statusCode) else {
                // Provider error bodies may echo request context. Keep them out of notifications,
                // logs, and crash reports while retaining the actionable HTTP boundary.
                throw CloudTranscriptionError.apiRequestFailed(
                    statusCode: http.statusCode,
                    message: "OpenAI transcription request was rejected."
                )
            }

            let text = try JSONDecoder().decode(Response.self, from: data).text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CloudTranscriptionError.noTranscriptionReturned
            }
            return text
        } catch let error as CloudTranscriptionError {
            throw error
        } catch {
            throw CloudTranscriptionError.networkError(error)
        }
    }

    private static func multipartBody(
        audioData: Data,
        fileName: String,
        boundary: String,
        fields: [(name: String, value: String)]
    ) -> Data {
        let crlf = "\r\n"
        let safeFileName = fileName
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
        var body = Data()

        func append(_ string: String) {
            body.append(string.data(using: .utf8)!)
        }

        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFileName)\"\(crlf)")
        append("Content-Type: audio/wav\(crlf)\(crlf)")
        body.append(audioData)
        append(crlf)

        for field in fields {
            append("--\(boundary)\(crlf)")
            append("Content-Disposition: form-data; name=\"\(field.name)\"\(crlf)\(crlf)")
            append(field.value)
            append(crlf)
        }

        append("--\(boundary)--\(crlf)")
        return body
    }
}

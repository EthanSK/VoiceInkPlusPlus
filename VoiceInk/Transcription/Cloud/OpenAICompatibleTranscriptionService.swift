import Foundation
import os

class OpenAICompatibleTranscriptionService {
    static let maximumVocabularyTermUTF8ByteCount = 256
    static let maximumVocabularyBlockUTF8ByteCount = 8 * 1_024
    private static let maximumVocabularyTermCount = 100
    private static let vocabularyStartMarker = "<VOICEINK_CUSTOM_VOCABULARY>"
    private static let vocabularyEndMarker = "</VOICEINK_CUSTOM_VOCABULARY>"

    // VIPPDebug: client-side view of the local Deepgram proxy round-trip. Pairs with the
    // proxy's own 200/500-BrokenPipe log so we can tell, from the APP side, whether an
    // upload completed (200), failed, or was CANCELLED mid-flight (URLError.cancelled →
    // the BrokenPipe the proxy sees). Filter:
    //   log stream --predicate 'subsystem == "com.ethansk.VoiceInkPlusPlus" && category == "VIPPDebug"'
    private let vippLog = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "VIPPDebug")

    // Dedicated URLSession with EXTENDED timeouts instead of URLSession.shared.
    // WHY: URLSession.shared uses the default 60s request timeout. OpenAI-compatible
    // proxies (esp. ones doing their own upstream retries) can hold a multipart audio
    // upload open well past 60s, and tripping the 60s wall mid-proxy-retry surfaced as
    // intermittent BrokenPipe / 500 errors — a transient timeout masquerading as a
    // server failure. 180s per-request + 300s per-resource gives slow proxies room to
    // finish without changing any success-path behavior.
    private let urlSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 180   // per-request inactivity window (was default 60s)
        cfg.timeoutIntervalForResource = 300  // total wall-clock cap for the whole upload+response
        return URLSession(configuration: cfg)
    }()

    func transcribe(
        audioURL: URL,
        model: CustomCloudModel,
        context: TranscriptionRequestContext,
        customVocabulary: [String]
    ) async throws -> String {
        guard let url = URL(string: model.apiEndpoint) else {
            throw NSError(domain: "CustomWhisperTranscriptionService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid API endpoint URL"])
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(model.apiKey)", forHTTPHeaderField: "Authorization")

        let body = try buildRequestBody(
            audioURL: audioURL,
            modelName: model.modelName,
            boundary: boundary,
            context: context,
            customVocabulary: customVocabulary
        )
        let loggedEndpoint = Self.endpointForLogging(url)
        vippLog.info("cloud upload START endpoint=\(loggedEndpoint, privacy: .public) bytes=\(body.count, privacy: .public)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.upload(for: request, from: body)
        } catch {
            // VIPPDebug: an error here with URLError.cancelled is the BrokenPipe-500 case:
            // the enclosing Task (key-event / pipeline) was cancelled, so URLSession aborts
            // the upload and the proxy sees the client close the socket. Any other error is
            // a genuine network failure / timeout. Re-throw unchanged.
            let isCancelled = (error as? URLError)?.code == .cancelled
            let nsError = error as NSError
            // URLSession diagnostics can repeat the complete request URL. Log only
            // the scrubbed endpoint plus stable error identity so credentials in URL
            // userinfo, query parameters, or fragments never enter durable logs.
            vippLog.error("cloud upload THREW endpoint=\(loggedEndpoint, privacy: .public) isCancelled=\(isCancelled, privacy: .public) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public)")
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            vippLog.error("cloud upload END non-HTTP response")
            throw CloudTranscriptionError.networkError(URLError(.badServerResponse))
        }

        vippLog.info("cloud upload END status=\(httpResponse.statusCode, privacy: .public) bytes=\(data.count, privacy: .public)")

        if !(200...299).contains(httpResponse.statusCode) {
            throw CloudTranscriptionError.apiRequestFailed(
                statusCode: httpResponse.statusCode,
                message: Self.sanitizedProviderErrorMessage(responseBody: data)
            )
        }

        do {
            return try JSONDecoder().decode(TranscriptionResponse.self, from: data).text
        } catch {
            throw CloudTranscriptionError.noTranscriptionReturned
        }
    }

    private func buildRequestBody(
        audioURL: URL,
        modelName: String,
        boundary: String,
        context: TranscriptionRequestContext,
        customVocabulary: [String]
    ) throws -> Data {
        guard let audioData = try? Data(contentsOf: audioURL) else {
            throw CloudTranscriptionError.audioFileNotFound
        }

        let selectedLanguage = context.language ?? "auto"
        let prompt = Self.promptForOpenAICompatibleRequest(
            userPrompt: context.prompt,
            customVocabulary: customVocabulary
        ) ?? ""
        let crlf = "\r\n"
        var body = Data()

        func append(_ string: String) { body.append(string.data(using: .utf8)!) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\(crlf)")
            append("Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)")
            body.append(value.data(using: .utf8)!)
            append(crlf)
        }

        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\(crlf)")
        append("Content-Type: audio/wav\(crlf)\(crlf)")
        body.append(audioData)
        append(crlf)

        field("model", modelName)
        field("response_format", "json")
        field("temperature", "0")

        if selectedLanguage != "auto" && !selectedLanguage.isEmpty {
            field("language", selectedLanguage)
        }
        if !prompt.isEmpty {
            field("prompt", prompt)
        }

        append("--\(boundary)--\(crlf)")
        return body
    }

    /// OpenAI-compatible transcription APIs have no portable `vocabulary` multipart
    /// field, but they do define `prompt` as the spelling/context hint. Encode VoiceInk++
    /// terms in that standard field so generic custom providers remain compatible. The
    /// explicit markers also let Ethan's local Deepgram adapter extract the same terms
    /// as native Nova-3 `keyterm` values without mistaking an ordinary user prompt for a
    /// vocabulary list. Bound each normalized term and the exact emitted block in UTF-8
    /// bytes so one malformed dictionary row cannot create an unbounded provider request.
    static func promptForOpenAICompatibleRequest(
        userPrompt: String?,
        customVocabulary: [String]
    ) -> String? {
        let trimmedUserPrompt = userPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedUserPrompt = trimmedUserPrompt?
            .replacingOccurrences(
                of: vocabularyStartMarker,
                with: "[VOICEINK CUSTOM VOCABULARY]",
                options: .caseInsensitive
            )
            .replacingOccurrences(
                of: vocabularyEndMarker,
                with: "[/VOICEINK CUSTOM VOCABULARY]",
                options: .caseInsensitive
            )

        var seen = Set<String>()
        var terms: [String] = []
        for rawTerm in customVocabulary {
            // One dictionary row must remain one marked prompt row. Collapse
            // embedded whitespace and reject our own delimiters so a malformed or
            // pasted multi-line term cannot escape the vocabulary block and be
            // mistaken for ordinary provider instructions.
            let normalizedTerm = rawTerm
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            guard !normalizedTerm.isEmpty else { continue }
            guard !normalizedTerm.lowercased().contains("voiceink_custom_vocabulary") else {
                continue
            }

            // Truncate only at a Swift Character boundary. Counting bytes after
            // normalization makes the cap deterministic while preserving valid UTF-8
            // and whole extended grapheme clusters (including joined emoji).
            let term = vocabularyTermPrefix(
                normalizedTerm,
                maximumUTF8ByteCount: maximumVocabularyTermUTF8ByteCount
            )
            guard !term.isEmpty else { continue }
            let key = term.lowercased()
            guard seen.insert(key).inserted else { continue }

            let candidateTerms = terms + [term]
            guard vocabularyBlock(for: candidateTerms).utf8.count
                    <= maximumVocabularyBlockUTF8ByteCount else {
                // A later shorter term may still fit. Continue scanning while keeping
                // all admitted terms in their original first-seen order.
                continue
            }
            terms.append(term)
            if terms.count == maximumVocabularyTermCount {
                break
            }
        }

        var sections: [String] = []
        if let sanitizedUserPrompt, !sanitizedUserPrompt.isEmpty {
            // App/window context is ordinary spelling guidance, never authority to
            // mint Deepgram keyterms. Remove the reserved delimiters so captured web
            // content cannot masquerade as the app-generated vocabulary block.
            sections.append(sanitizedUserPrompt)
        }
        if !terms.isEmpty {
            sections.append(vocabularyBlock(for: terms))
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    /// Keep provider diagnostics useful without persisting URL credentials or request
    /// tokens. Never fall back to the original string if component serialization fails.
    static func endpointForLogging(_ endpoint: URL) -> String {
        guard var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            return "<unavailable endpoint>"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "<unavailable endpoint>"
    }

    private static func vocabularyTermPrefix(
        _ term: String,
        maximumUTF8ByteCount: Int
    ) -> String {
        var result = ""
        var byteCount = 0
        for character in term {
            let characterByteCount = String(character).utf8.count
            guard byteCount + characterByteCount <= maximumUTF8ByteCount else {
                break
            }
            result.append(character)
            byteCount += characterByteCount
        }
        return result
    }

    private static func vocabularyBlock(for terms: [String]) -> String {
        ([vocabularyStartMarker]
            + terms.map { "- \($0)" }
            + [vocabularyEndMarker])
            .joined(separator: "\n")
    }

    /// Custom OpenAI-compatible providers control their error response body and may
    /// echo the multipart prompt, request URL, or rejected vocabulary term. Pipeline
    /// failures are persisted and surfaced to the user, so forwarding that body would
    /// turn a provider diagnostic into a durable local disclosure. Keep the HTTP status
    /// in the typed error, but replace every untrusted body with one useful safe message.
    static func sanitizedProviderErrorMessage(responseBody _: Data) -> String {
        "The transcription provider returned an error response. Response details were omitted to protect request context and vocabulary."
    }

    private struct TranscriptionResponse: Decodable {
        let text: String
        let language: String?
        let duration: Double?
    }
}

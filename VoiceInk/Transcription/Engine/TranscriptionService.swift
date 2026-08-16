import Foundation

struct TranscriptionRequestContext {
    let language: String?
    /// The existing static `TranscriptionPrompt`. Never rewritten: every provider except
    /// the OpenAI transcription models receives exactly these legacy bytes.
    let prompt: String?
    /// Opt-in composed prompt (static prompt first, recent-dictation context appended
    /// inside the same 4,096-character cap). `nil` means "nothing eligible was appended",
    /// which keeps the legacy request byte-identical.
    let promptWithRecentContext: String?
    /// Vocabulary keywords frozen with this recording. `nil` means no snapshot was taken
    /// and the provider path performs its own legacy live fetch.
    let vocabulary: [String]?

    init(
        language: String?,
        prompt: String?,
        promptWithRecentContext: String? = nil,
        vocabulary: [String]? = nil
    ) {
        self.language = language
        self.prompt = prompt
        self.promptWithRecentContext = promptWithRecentContext
        self.vocabulary = vocabulary
    }

    /// Prompt for the OpenAI transcription models only.
    ///
    /// Recent-dictation context is deliberately scoped to OpenAI because that is where it
    /// was designed and capped. The realtime session and its completed-audio fallback both
    /// read this same frozen value, so one recording can never send two different prompts.
    var openAITranscriptionPrompt: String? {
        promptWithRecentContext ?? prompt
    }

    /// Frozen keywords when this recording captured a snapshot, otherwise the caller's
    /// existing live fetch.
    func customVocabulary(orLiveFetch liveFetch: () -> [String]) -> [String] {
        vocabulary ?? liveFetch()
    }

    static var currentDefaults: TranscriptionRequestContext {
        TranscriptionRequestContext(
            language: UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "auto",
            prompt: UserDefaults.standard.string(forKey: "TranscriptionPrompt")
        )
    }
}

/// A protocol defining the interface for a transcription service.
/// This allows for a unified way to handle both local and cloud-based transcription models.
protocol TranscriptionService {
    /// Transcribes the audio from a given file URL.
    ///
    /// - Parameters:
    ///   - audioURL: The URL of the audio file to transcribe.
    ///   - model: The `TranscriptionModel` to use for transcription. This provides context about the provider (local, OpenAI, etc.).
    /// - Returns: The transcribed text as a `String`.
    /// - Throws: An error if the transcription fails.
    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> String
}

extension TranscriptionService {
    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        try await transcribe(audioURL: audioURL, model: model, context: .currentDefaults)
    }
}

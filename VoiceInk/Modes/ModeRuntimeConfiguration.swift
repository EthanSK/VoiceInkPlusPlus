import Foundation

struct TranscriptionRuntimeConfiguration {
    let mode: ModeConfig?
    let model: any TranscriptionModel
    let language: String
    let isRealtimeEnabled: Bool

    var metadata: (name: String?, emoji: String?) {
        guard let mode, mode.isEnabled else {
            return (nil, nil)
        }
        return (mode.name, mode.icon.value)
    }

    var requestContext: TranscriptionRequestContext {
        TranscriptionRequestContext(
            language: language,
            prompt: UserDefaults.standard.string(forKey: "TranscriptionPrompt")
        )
    }
}

struct TranscriptionFormattingConfiguration {
    let mode: ModeConfig?
    let isTextFormattingEnabled: Bool
}

struct EnhancementRuntimeConfiguration {
    let mode: ModeConfig?
    let isEnabled: Bool
    let prompt: CustomPrompt?
    let provider: AIProvider?
    let modelName: String?
    let useClipboardContext: Bool
    let useSelectedTextContext: Bool
    let useScreenCaptureContext: Bool

    func replacingPrompt(_ prompt: CustomPrompt) -> EnhancementRuntimeConfiguration {
        EnhancementRuntimeConfiguration(
            mode: mode,
            isEnabled: true,
            prompt: prompt,
            provider: provider,
            modelName: modelName,
            useClipboardContext: useClipboardContext,
            useSelectedTextContext: useSelectedTextContext,
            useScreenCaptureContext: useScreenCaptureContext
        )
    }
}

struct OutputRuntimeConfiguration {
    let mode: ModeConfig?
    let outputMode: ModeOutputMode
    let autoSendKey: AutoSendKey
    let customCommand: ModeCustomCommand?
}

@MainActor
enum ModeRuntimeResolver {
    static func transcriptionConfiguration(
        mode: ModeConfig? = nil,
        transcriptionModelManager: TranscriptionModelManager
    ) -> TranscriptionRuntimeConfiguration? {
        makeTranscriptionConfiguration(
            mode: mode ?? ModeManager.shared.currentEffectiveConfiguration,
            transcriptionModelManager: transcriptionModelManager
        )
    }

    /// Resolve from an already-bound per-session Mode value. Here nil is deliberately
    /// neutral and must not fall through to whichever global Mode became current while
    /// microphone/browser setup was suspended.
    static func snapshotTranscriptionConfiguration(
        mode: ModeConfig?,
        transcriptionModelManager: TranscriptionModelManager
    ) -> TranscriptionRuntimeConfiguration? {
        makeTranscriptionConfiguration(
            mode: mode,
            transcriptionModelManager: transcriptionModelManager
        )
    }

    private static func makeTranscriptionConfiguration(
        mode: ModeConfig?,
        transcriptionModelManager: TranscriptionModelManager
    ) -> TranscriptionRuntimeConfiguration? {
        let model = resolvedModel(
            named: mode?.selectedTranscriptionModelName,
            transcriptionModelManager: transcriptionModelManager
        )

        guard let model else { return nil }

        let language = TranscriptionLanguageSupport.validLanguageOrFallback(
            mode?.selectedLanguage,
            for: model,
            realtimeEnabled: mode?.isRealtimeTranscriptionEnabled
        )

        return TranscriptionRuntimeConfiguration(
            mode: mode,
            model: model,
            language: language,
            isRealtimeEnabled: TranscriptionRealtimeSupport.isEnabled(for: model, modeValue: mode?.isRealtimeTranscriptionEnabled)
        )
    }

    static func transcriptionFormattingConfiguration(mode: ModeConfig? = nil) -> TranscriptionFormattingConfiguration {
        makeTranscriptionFormattingConfiguration(
            mode: mode ?? ModeManager.shared.currentEffectiveConfiguration
        )
    }

    /// Resolve formatting for a saved destination. Unlike the general resolver above,
    /// `nil` is deliberately neutral: it must not fall through to whichever unrelated
    /// Mode became current after this recording chose its exact input.
    static func pasteTargetTranscriptionFormattingConfiguration(
        mode: ModeConfig?
    ) -> TranscriptionFormattingConfiguration {
        makeTranscriptionFormattingConfiguration(mode: mode)
    }

    private static func makeTranscriptionFormattingConfiguration(
        mode: ModeConfig?
    ) -> TranscriptionFormattingConfiguration {

        return TranscriptionFormattingConfiguration(
            mode: mode,
            isTextFormattingEnabled: mode?.isTextFormattingEnabled ?? UserDefaults.standard.bool(forKey: "IsTextFormattingEnabled")
        )
    }

    static func currentEnhancementConfiguration(
        mode: ModeConfig? = nil,
        enhancementService: AIEnhancementService,
        aiService: AIService
    ) -> EnhancementRuntimeConfiguration {
        makeEnhancementConfiguration(
            mode: mode ?? ModeManager.shared.currentEffectiveConfiguration,
            enhancementService: enhancementService,
            aiService: aiService
        )
    }

    /// Resolve enhancement from the destination-owned Mode snapshot. A target with
    /// no matching/default Mode is intentionally plain and cannot inherit the live
    /// Mode from an app Ethan focused later.
    static func pasteTargetEnhancementConfiguration(
        mode: ModeConfig?,
        enhancementService: AIEnhancementService,
        aiService: AIService
    ) -> EnhancementRuntimeConfiguration {
        makeEnhancementConfiguration(
            mode: mode,
            enhancementService: enhancementService,
            aiService: aiService
        )
    }

    private static func makeEnhancementConfiguration(
        mode: ModeConfig?,
        enhancementService: AIEnhancementService,
        aiService: AIService
    ) -> EnhancementRuntimeConfiguration {
        let prompt = resolvedPrompt(
            promptId: mode?.selectedPrompt,
            enhancementService: enhancementService
        )
        let provider = resolvedProvider(
            providerName: mode?.selectedAIProvider,
            aiService: aiService
        )
        let modelName = resolvedEnhancementModelName(
            provider: provider,
            configuredModelName: mode?.selectedAIModel,
            aiService: aiService
        )

        return EnhancementRuntimeConfiguration(
            mode: mode,
            isEnabled: mode?.isAIEnhancementEnabled ?? false,
            prompt: prompt,
            provider: provider,
            modelName: modelName,
            useClipboardContext: mode?.useClipboardContext ?? false,
            useSelectedTextContext: mode?.useSelectedTextContext ?? true,
            useScreenCaptureContext: mode?.useScreenCapture ?? false
        )
    }

    static func outputConfiguration(mode: ModeConfig? = nil) -> OutputRuntimeConfiguration {
        makeOutputConfiguration(
            mode: mode ?? ModeManager.shared.currentEffectiveConfiguration
        )
    }

    /// Resolve the complete delivery action owned by a saved paste target. This is
    /// intentionally separate from `outputConfiguration`: `nil` means neutral paste,
    /// never "look at the current global Mode".
    static func pasteTargetOutputConfiguration(mode: ModeConfig?) -> OutputRuntimeConfiguration {
        makeOutputConfiguration(mode: mode)
    }

    private static func makeOutputConfiguration(mode: ModeConfig?) -> OutputRuntimeConfiguration {

        return OutputRuntimeConfiguration(
            mode: mode,
            outputMode: mode?.outputMode ?? .paste,
            autoSendKey: mode?.autoSendKey ?? .none,
            customCommand: mode?.customCommand
        )
    }

    /// Capture the complete value-type Mode owned by a saved paste destination.
    /// Destination selection and Mode selection are one atomic per-session decision:
    /// later focus changes must not mix another app's formatting/output/script/Return
    /// behavior into the exact input that will receive this transcript.
    static func modeSnapshot(
        forPasteTargetBundleIdentifier bundleIdentifier: String?,
        applicationBundleName: String? = nil
    ) -> ModeConfig? {
        guard let bundleIdentifier else { return nil }
        // Never consume currentEffectiveConfiguration here. It is mutable global UI
        // state and can still describe the previous app—or a different tab in the same
        // browser—when an Accessibility capture has just selected a new exact input.
        // Exact destination capture does not prove a browser tab identity, so
        // ActiveWindowService.resolveConfigurationForCapturedTarget deliberately keeps
        // this app/default snapshot instead of attaching whichever URL is current later.
        let modeBundleIdentifier = ActiveWindowService.modeLookupBundleIdentifier(
            capturedBundleIdentifier: bundleIdentifier,
            applicationBundleName: applicationBundleName
        )
        return ModeManager.shared.getConfigurationForApp(modeBundleIdentifier)
            ?? ModeManager.shared.getDefaultConfiguration()
    }

    static func autoSendKey(forPasteTargetBundleIdentifier bundleIdentifier: String?) -> AutoSendKey {
        modeSnapshot(forPasteTargetBundleIdentifier: bundleIdentifier)?.autoSendKey ?? .none
    }

    private static func resolvedModel(
        named modelName: String?,
        transcriptionModelManager: TranscriptionModelManager
    ) -> (any TranscriptionModel)? {
        if let modelName,
           let model = transcriptionModelManager.usableModels.first(where: { $0.name == modelName }) {
            return model
        }

        return transcriptionModelManager.usableModels.first
    }

    private static func resolvedPrompt(
        promptId: String?,
        enhancementService: AIEnhancementService
    ) -> CustomPrompt? {
        guard let promptId,
              let uuid = UUID(uuidString: promptId) else {
            return nil
        }

        return enhancementService.allPrompts.first { $0.id == uuid }
    }

    private static func resolvedProvider(
        providerName: String?,
        aiService: AIService
    ) -> AIProvider? {
        if let providerName,
           let provider = AIProvider(rawValue: providerName),
           aiService.connectedProviders.contains(provider) {
            return provider
        }

        return aiService.connectedProviders.first
    }

    private static func resolvedEnhancementModelName(
        provider: AIProvider?,
        configuredModelName: String?,
        aiService: AIService
    ) -> String? {
        guard let provider else { return nil }

        if provider == .localCLI {
            return nil
        }

        let models = aiService.availableModels(for: provider)
        if let configuredModelName,
           !configuredModelName.isEmpty,
           (models.isEmpty || models.contains(configuredModelName)) {
            return configuredModelName
        }

        if let firstModel = models.first {
            return firstModel
        }

        return provider.defaultModel
    }
}

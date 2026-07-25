import Foundation

// Safe to delete once all users have updated past this version.
enum StreamingKeysMigration {
    static let assemblyAI35ModelMappings: [String: String] = [
        "universal-3-pro": AssemblyAIStreamingConnectionConfiguration.universal35ProModelName,
        "u3-rt-pro": AssemblyAIStreamingConnectionConfiguration.universal35ProModelName,
    ]

    static func run() {
        let defaults = UserDefaults.standard
        migrateAssemblyAI35ModelNamesIfNeeded(defaults: defaults)
        guard !defaults.bool(forKey: "streaming-keys-migrated") else { return }

        let legacyStreamingMappings: [(old: String, new: [String])] = [
            ("parakeet-streaming-enabled", [
                "streaming-enabled-parakeet-tdt-0.6b-v2",
                "streaming-enabled-parakeet-tdt-0.6b-v3",
            ]),
        ]

        for mapping in legacyStreamingMappings {
            if let value = defaults.object(forKey: mapping.old) as? Bool {
                for newKey in mapping.new {
                    defaults.set(value, forKey: newKey)
                }
                defaults.removeObject(forKey: mapping.old)
            }
        }

        // Remap CurrentTranscriptionModel if it points to a removed streaming-only model name.
        let removedModelMappings: [String: String] = [
            "stt-rt-v4": "stt-async-v4",
            "voxtral-mini-transcribe-realtime-2602": "voxtral-mini-latest",
        ]

        remapSavedModelNames(removedModelMappings, defaults: defaults)

        defaults.set(true, forKey: "streaming-keys-migrated")
    }

    private static func migrateAssemblyAI35ModelNamesIfNeeded(defaults: UserDefaults) {
        let migrationKey = "assemblyai-3-5-model-migrated"
        guard !defaults.bool(forKey: migrationKey) else { return }

        remapSavedModelNames(assemblyAI35ModelMappings, defaults: defaults)
        defaults.set(true, forKey: migrationKey)
    }

    private static func remapSavedModelNames(
        _ mappings: [String: String],
        defaults: UserDefaults
    ) {
        if let savedModel = defaults.string(forKey: "CurrentTranscriptionModel"),
           let replacement = mappings[savedModel] {
            defaults.set(replacement, forKey: "CurrentTranscriptionModel")
        }

        // Check both the renamed key and the legacy key so older saved data is fixed
        // before ModeDataMigration copies it forward. JSONSerialization keeps this
        // migration independent of the ModeConfig struct shape.
        for modeKey in ["modeConfigurationsV2", "powerModeConfigurationsV2"] {
            guard let data = defaults.data(forKey: modeKey),
                  var configs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                continue
            }

            var changed = false
            for index in configs.indices {
                guard let savedModel = configs[index]["selectedTranscriptionModelName"] as? String,
                      let replacement = mappings[savedModel] else {
                    continue
                }
                configs[index]["selectedTranscriptionModelName"] = replacement
                changed = true
            }

            if changed, let newData = try? JSONSerialization.data(withJSONObject: configs) {
                defaults.set(newData, forKey: modeKey)
            }
        }
    }
}

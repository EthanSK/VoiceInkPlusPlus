#!/usr/bin/env swift

import Foundation

private enum ProbeFailure: Error, CustomStringConvertible {
    case usage
    case missingAPIKey
    case invalidAudio(String)
    case timeout(String)
    case server(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: openai-transcription-probe.swift <pcm16-mono-24khz> <wav>"
        case .missingAPIKey:
            return "VoiceInk++ has no stored OpenAI key"
        case .invalidAudio(let message), .timeout(let message), .server(let message):
            return message
        }
    }
}

private let defaultsDomain = "com.ethansk.VoiceInkPlusPlus"
private let keyName = "LocalKeychain_openAIAPIKey"
private let liveModel = "gpt-live-transcribe"
private let completedModel = "gpt-transcribe"

private func storedAPIKey() throws -> String {
    guard let data = UserDefaults(suiteName: defaultsDomain)?.data(forKey: keyName),
          let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          key.hasPrefix("sk-"),
          key.count > 40 else {
        throw ProbeFailure.missingAPIKey
    }
    return key
}

private func encodedJSON(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object)
    guard let text = String(data: data, encoding: .utf8) else {
        throw ProbeFailure.server("could not encode JSON")
    }
    return text
}

private func receiveJSON(from task: URLSessionWebSocketTask, boundary: String) async throws -> [String: Any] {
    try await withThrowingTaskGroup(of: [String: Any].self) { group in
        group.addTask {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .string(let text):
                data = Data(text.utf8)
            case .data(let binary):
                data = binary
            @unknown default:
                throw ProbeFailure.server("unexpected WebSocket message")
            }
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ProbeFailure.server("invalid WebSocket JSON")
            }
            return value
        }
        group.addTask {
            try await Task.sleep(for: .seconds(30))
            throw ProbeFailure.timeout("timed out waiting for \(boundary)")
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else {
            throw ProbeFailure.timeout("timed out waiting for \(boundary)")
        }
        return value
    }
}

private func serverMessage(_ json: [String: Any]) -> String {
    if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
        return message
    }
    if let message = json["message"] as? String {
        return message
    }
    return "unknown server error"
}

private func probeLive(apiKey: String, pcmURL: URL) async throws -> String {
    let pcm = try Data(contentsOf: pcmURL)
    guard pcm.count >= 4_800, pcm.count.isMultiple(of: 2) else {
        throw ProbeFailure.invalidAudio("PCM probe must contain PCM16 mono 24 kHz audio")
    }

    var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
    components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 15

    let session = URLSession(configuration: .ephemeral)
    let task = session.webSocketTask(with: request)
    defer {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
    task.resume()

    let update: [String: Any] = [
        "type": "session.update",
        "session": [
            "type": "transcription",
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": 24_000],
                    "transcription": [
                        "model": liveModel,
                        "delay": "xhigh",
                        "prompt": "Synthetic VoiceInk provider verification.",
                        "languages": ["en"],
                        "keywords": ["VoiceInk", "transcription"],
                    ],
                    "turn_detection": NSNull(),
                ],
            ],
        ],
    ]
    try await task.send(.string(encodedJSON(update)))

    while true {
        let json = try await receiveJSON(from: task, boundary: "session.updated")
        switch json["type"] as? String {
        case "session.updated":
            break
        case "error":
            throw ProbeFailure.server("session update rejected: \(serverMessage(json))")
        default:
            continue
        }
        break
    }

    let chunkSize = 4_800
    var offset = 0
    while offset < pcm.count {
        let end = min(offset + chunkSize, pcm.count)
        let chunk = pcm.subdata(in: offset..<end)
        try await task.send(.string(encodedJSON([
            "type": "input_audio_buffer.append",
            "audio": chunk.base64EncodedString(),
        ])))
        offset = end
    }
    try await task.send(.string(encodedJSON(["type": "input_audio_buffer.commit"])))

    var deltaCount = 0
    var cumulative = ""
    while true {
        let json = try await receiveJSON(from: task, boundary: "completed transcript")
        switch json["type"] as? String {
        case "conversation.item.input_audio_transcription.delta":
            if let delta = json["delta"] as? String, !delta.isEmpty {
                deltaCount += 1
                cumulative += delta
            }
        case "conversation.item.input_audio_transcription.completed":
            let final = (json["transcript"] as? String) ?? cumulative
            guard !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProbeFailure.server("live completion was empty")
            }
            guard deltaCount > 0 else {
                throw ProbeFailure.server("live completion arrived without any delta")
            }
            print("LIVE_OK session_updated=true deltas=\(deltaCount) delay=xhigh language=en keywords=2")
            return final
        case "conversation.item.input_audio_transcription.failed", "error":
            throw ProbeFailure.server("live transcription rejected: \(serverMessage(json))")
        default:
            continue
        }
    }
}

private func appendField(_ name: String, _ value: String, boundary: String, to body: inout Data) {
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
    body.append(Data(value.utf8))
    body.append(Data("\r\n".utf8))
}

private func probeCompleted(apiKey: String, wavURL: URL) async throws -> String {
    let wav = try Data(contentsOf: wavURL)
    guard wav.count > 44, String(data: wav.prefix(4), encoding: .ascii) == "RIFF" else {
        throw ProbeFailure.invalidAudio("completed-audio probe must be a WAV file")
    }

    let boundary = "VoiceInkProbe-\(UUID().uuidString)"
    var body = Data()
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"voiceink-openai-probe.wav\"\r\n".utf8))
    body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
    body.append(wav)
    body.append(Data("\r\n".utf8))
    appendField("model", completedModel, boundary: boundary, to: &body)
    appendField("response_format", "json", boundary: boundary, to: &body)
    appendField("prompt", "Synthetic VoiceInk provider verification.", boundary: boundary, to: &body)
    appendField("languages[]", "en", boundary: boundary, to: &body)
    appendField("keywords[]", "VoiceInk", boundary: boundary, to: &body)
    appendField("keywords[]", "transcription", boundary: boundary, to: &body)
    body.append(Data("--\(boundary)--\r\n".utf8))

    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    let (data, response) = try await URLSession.shared.upload(for: request, from: body)
    guard let http = response as? HTTPURLResponse else {
        throw ProbeFailure.server("completed-audio response was not HTTP")
    }
    guard (200..<300).contains(http.statusCode) else {
        let detail = String(data: data.prefix(500), encoding: .utf8) ?? "unreadable response"
        throw ProbeFailure.server("completed-audio HTTP \(http.statusCode): \(detail)")
    }
    guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let text = payload["text"] as? String,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProbeFailure.server("completed-audio transcript was empty")
    }
    print("COMPLETED_OK model=gpt-transcribe language_array=true keywords=2")
    return text
}

private func run() async throws {
    guard CommandLine.arguments.count == 3 else { throw ProbeFailure.usage }
    let key = try storedAPIKey()
    let live = try await probeLive(apiKey: key, pcmURL: URL(fileURLWithPath: CommandLine.arguments[1]))
    let completed = try await probeCompleted(apiKey: key, wavURL: URL(fileURLWithPath: CommandLine.arguments[2]))
    // Keep probe output privacy-bounded. Callers need success and shape evidence,
    // not transcript contents from an accidentally supplied real recording.
    print("RESULT live_characters=\(live.count) completed_characters=\(completed.count)")
}

Task {
    do {
        try await run()
        exit(EXIT_SUCCESS)
    } catch {
        fputs("PROBE_FAILED \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
}
dispatchMain()

import Foundation
import SwiftData
import os

/// A small, local write-ahead record for the one microphone capture VoiceInk++ can
/// own at a time. `ExtAudioFile` updates a WAV header only when it closes, so a
/// force-quit or power loss can otherwise leave successfully written PCM with no
/// History row and a stale header. The journal is created before AUHAL starts and
/// is removed only after SwiftData durably owns the same audio URL.
///
/// The journal deliberately contains no destination, Mode, focus, or delivery state:
/// recovery is History-only and must never paste, submit, or recreate a live route.
struct RecordingRecoveryJournalEntry: Codable, Equatable, Sendable {
    let id: UUID
    let audioFilePath: String
    let startedAt: Date
    let sampleRate: UInt32
    let channelCount: UInt16
    let bitsPerSample: UInt16
    var realtimeDraftText: String?
    var inputDeviceName: String?
    var inputDeviceUID: String?

    init(
        id: UUID = UUID(),
        audioURL: URL,
        startedAt: Date = Date(),
        sampleRate: UInt32 = 16_000,
        channelCount: UInt16 = 1,
        bitsPerSample: UInt16 = 16,
        realtimeDraftText: String? = nil,
        inputDeviceName: String? = nil,
        inputDeviceUID: String? = nil
    ) {
        self.id = id
        self.audioFilePath = audioURL.path
        self.startedAt = startedAt
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitsPerSample = bitsPerSample
        self.realtimeDraftText = Self.normalized(realtimeDraftText)
        self.inputDeviceName = Self.normalized(inputDeviceName)
        self.inputDeviceUID = Self.normalized(inputDeviceUID)
    }

    var audioURL: URL { URL(fileURLWithPath: audioFilePath) }

    mutating func update(
        realtimeDraftText: String?,
        inputDevice: RecordingInputDeviceSnapshot?
    ) {
        self.realtimeDraftText = Self.normalized(realtimeDraftText)
        if let inputDevice {
            inputDeviceName = inputDevice.name
            inputDeviceUID = inputDevice.uid
        }
    }

    var inputDeviceSnapshot: RecordingInputDeviceSnapshot? {
        RecordingInputDeviceSnapshot(name: inputDeviceName, uid: inputDeviceUID)
    }

    private static func normalized(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

/// File-system boundary for active-capture journals. It is intentionally injectable
/// so the recovery parser is testable without looking at Ethan's live recordings.
struct RecordingRecoveryJournalStore {
    struct PendingEntry {
        let journalURL: URL
        let entry: RecordingRecoveryJournalEntry
    }

    enum PendingJournal {
        case entry(PendingEntry)
        case unreadable(URL)
    }

    let directory: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(directory: URL = RecordingRecoveryJournalStore.defaultDirectory) {
        self.directory = directory
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.ethansk.VoiceInkPlusPlus", isDirectory: true)
            .appendingPathComponent("RecordingRecovery", isDirectory: true)
    }

    func begin(audioURL: URL) throws -> RecordingRecoveryJournalEntry {
        let entry = RecordingRecoveryJournalEntry(audioURL: audioURL)
        try persist(entry)
        return entry
    }

    func persist(_ entry: RecordingRecoveryJournalEntry) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(entry)
        // Atomic replacement means launch recovery sees either the previous complete
        // snapshot or the new one—never a truncated JSON file after interruption.
        try data.write(to: journalURL(for: entry), options: .atomic)
    }

    func remove(_ entry: RecordingRecoveryJournalEntry) throws {
        let url = journalURL(for: entry)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func pendingJournals() -> [PendingJournal] {
        guard FileManager.default.fileExists(atPath: directory.path),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              )
        else {
            return []
        }

        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                guard let data = try? Data(contentsOf: url),
                      let entry = try? decoder.decode(RecordingRecoveryJournalEntry.self, from: data)
                else {
                    return .unreadable(url)
                }
                return .entry(PendingEntry(journalURL: url, entry: entry))
            }
    }

    private func journalURL(for entry: RecordingRecoveryJournalEntry) -> URL {
        directory.appendingPathComponent("\(entry.id.uuidString).json")
    }
}

/// Startup-only recovery. It repairs only the exact PCM16 mono WAV layout produced by
/// CoreAudioRecorder and leaves every unknown/corrupt file plus its journal untouched.
/// That fail-closed boundary is what makes retrying recovery safe after another launch.
@MainActor
enum RecordingCrashRecoveryService {
    struct Summary: Equatable {
        var recoveredCount = 0
        var discardedEmptyStartCount = 0
        var retainedForManualRecoveryCount = 0

        var hasVisibleResult: Bool {
            recoveredCount > 0 || retainedForManualRecoveryCount > 0
        }
    }

    enum WAVRepairResult: Equatable {
        case alreadyFinalized(duration: TimeInterval)
        case repaired(duration: TimeInterval)
    }

    enum WAVRepairError: Error, Equatable {
        case unsupportedContainer
        case missingFormatChunk
        case unsupportedFormat
        case missingDataChunk
        case invalidDataLength
        case unableToReplaceOriginal
    }

    private static let logger = Logger(
        subsystem: "com.ethansk.VoiceInkPlusPlus",
        category: "RecordingCrashRecovery"
    )

    static func recoverPendingRecordings(
        modelContext: ModelContext,
        journalStore: RecordingRecoveryJournalStore = RecordingRecoveryJournalStore()
    ) -> Summary {
        var summary = Summary()

        for journal in journalStore.pendingJournals() {
            switch journal {
            case .unreadable(let journalURL):
                // Do not delete unknown bytes: this could be the sole evidence of an
                // interrupted recording. The launch warning asks Ethan to keep it.
                logger.error("Retaining unreadable recording recovery journal file=\(journalURL.lastPathComponent, privacy: .public)")
                summary.retainedForManualRecoveryCount += 1

            case .entry(let pending):
                let entry = pending.entry
                let audioURL = entry.audioURL
                guard FileManager.default.fileExists(atPath: audioURL.path) else {
                    // The journal is written before AUHAL starts. If capture never
                    // produced a file, this is a proven empty start rather than lost audio.
                    do {
                        try journalStore.remove(entry)
                        summary.discardedEmptyStartCount += 1
                    } catch {
                        logger.error("Could not remove empty-start recovery journal id=\(entry.id.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
                        summary.retainedForManualRecoveryCount += 1
                    }
                    continue
                }

                let audioURLString = audioURL.absoluteString
                let descriptor = FetchDescriptor<Transcription>(
                    predicate: #Predicate<Transcription> { transcription in
                        transcription.audioFileURL == audioURLString
                    }
                )
                if (try? modelContext.fetch(descriptor).isEmpty) == false {
                    // A normal stop persisted its History row but died before it could
                    // clear the journal. The existing row is authoritative; remove only
                    // the redundant marker and never create a duplicate recovery entry.
                    do {
                        try journalStore.remove(entry)
                    } catch {
                        logger.error("Could not clear already-persisted recording journal id=\(entry.id.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
                    }
                    continue
                }

                do {
                    let repair = try repairPCM16WAV(at: audioURL, expected: entry)
                    let duration: TimeInterval
                    switch repair {
                    case .alreadyFinalized(let value), .repaired(let value):
                        duration = value
                    }

                    let draft = entry.realtimeDraftText
                    let transcription = Transcription(
                        text: draft ?? String(localized: "Interrupted recording recovered — replay or retranscribe its saved audio."),
                        duration: duration,
                        audioFileURL: audioURL.absoluteString,
                        recordingInputDevice: entry.inputDeviceSnapshot,
                        realtimeDraftText: draft,
                        preservesOriginalAudioForRecovery: true,
                        transcriptionStatus: .recoveredAfterInterruption
                    )
                    modelContext.insert(transcription)
                    do {
                        try modelContext.save()
                    } catch {
                        // Never remove the journal if SwiftData cannot prove that the
                        // recovery row exists. Roll the in-memory insert back so a retry
                        // on next launch starts from the original durable state.
                        modelContext.delete(transcription)
                        logger.error("Could not save recovered recording id=\(entry.id.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
                        summary.retainedForManualRecoveryCount += 1
                        continue
                    }

                    do {
                        try journalStore.remove(entry)
                        summary.recoveredCount += 1
                        NotificationCenter.default.post(
                            name: .transcriptionCreated,
                            object: transcription
                        )
                    } catch {
                        // The History row is now durable. A later launch recognizes it
                        // by URL and clears the stale marker without duplicating audio.
                        logger.error("Recovered recording saved but journal cleanup failed id=\(entry.id.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
                    }
                } catch {
                    // Unknown RIFF layouts are kept byte-for-byte for a later manual
                    // recovery path rather than guessing at data offsets or deleting audio.
                    logger.error("Retaining interrupted recording for manual recovery id=\(entry.id.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
                    summary.retainedForManualRecoveryCount += 1
                }
            }
        }

        return summary
    }

    static func repairPCM16WAV(
        at url: URL,
        expected entry: RecordingRecoveryJournalEntry
    ) throws -> WAVRepairResult {
        var data = try Data(contentsOf: url)
        guard data.count >= 44,
              fourCC(in: data, at: 0) == "RIFF",
              fourCC(in: data, at: 8) == "WAVE"
        else {
            throw WAVRepairError.unsupportedContainer
        }

        var cursor = 12
        var isExpectedFormat = false
        var dataHeaderOffset: Int?
        while cursor + 8 <= data.count {
            guard let chunkID = fourCC(in: data, at: cursor),
                  let declaredLength = uint32LE(in: data, at: cursor + 4)
            else {
                throw WAVRepairError.unsupportedContainer
            }
            let contentOffset = cursor + 8
            if chunkID == "fmt " {
                guard contentOffset + 16 <= data.count,
                      let format = uint16LE(in: data, at: contentOffset),
                      let channels = uint16LE(in: data, at: contentOffset + 2),
                      let sampleRate = uint32LE(in: data, at: contentOffset + 4),
                      let byteRate = uint32LE(in: data, at: contentOffset + 8),
                      let blockAlign = uint16LE(in: data, at: contentOffset + 12),
                      let bitsPerSample = uint16LE(in: data, at: contentOffset + 14)
                else {
                    throw WAVRepairError.missingFormatChunk
                }
                let expectedBlockAlign = entry.channelCount * (entry.bitsPerSample / 8)
                let expectedByteRate = entry.sampleRate * UInt32(expectedBlockAlign)
                isExpectedFormat = format == 1
                    && channels == entry.channelCount
                    && sampleRate == entry.sampleRate
                    && byteRate == expectedByteRate
                    && blockAlign == expectedBlockAlign
                    && bitsPerSample == entry.bitsPerSample
            }
            if chunkID == "data" {
                dataHeaderOffset = cursor
                break
            }

            let paddedLength = Int(declaredLength) + (Int(declaredLength) % 2)
            guard contentOffset + paddedLength <= data.count else {
                throw WAVRepairError.unsupportedContainer
            }
            cursor = contentOffset + paddedLength
        }

        guard isExpectedFormat else { throw WAVRepairError.unsupportedFormat }
        guard let dataHeaderOffset else { throw WAVRepairError.missingDataChunk }
        let dataOffset = dataHeaderOffset + 8
        let payloadLength = data.count - dataOffset
        let bytesPerFrame = Int(entry.channelCount) * Int(entry.bitsPerSample / 8)
        guard payloadLength >= 0,
              bytesPerFrame > 0,
              payloadLength % bytesPerFrame == 0
        else {
            throw WAVRepairError.invalidDataLength
        }

        let expectedRiffLength = UInt32(data.count - 8)
        let expectedDataLength = UInt32(payloadLength)
        let wasFinalized = uint32LE(in: data, at: 4) == expectedRiffLength
            && uint32LE(in: data, at: dataHeaderOffset + 4) == expectedDataLength
        let duration = TimeInterval(payloadLength) / Double(entry.sampleRate * UInt32(bytesPerFrame))
        guard !wasFinalized else { return .alreadyFinalized(duration: duration) }

        writeUInt32LE(expectedRiffLength, into: &data, at: 4)
        writeUInt32LE(expectedDataLength, into: &data, at: dataHeaderOffset + 4)
        try atomicallyReplace(url, with: data)
        return .repaired(duration: duration)
    }

    private static func atomicallyReplace(_ originalURL: URL, with data: Data) throws {
        let temporaryURL = originalURL.deletingLastPathComponent()
            .appendingPathComponent(".\(originalURL.lastPathComponent).recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: .atomic)
        do {
            _ = try FileManager.default.replaceItemAt(
                originalURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } catch {
            throw WAVRepairError.unableToReplaceOriginal
        }
    }

    private static func fourCC(in data: Data, at offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return String(bytes: data[offset..<(offset + 4)], encoding: .ascii)
    }

    private static func uint16LE(in data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32LE(in data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func writeUInt32LE(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}

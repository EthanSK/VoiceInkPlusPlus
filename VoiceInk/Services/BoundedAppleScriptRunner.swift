import Darwin
import Foundation

struct BoundedAppleScriptResult {
    let stdout: String
}

enum BoundedAppleScriptError: Error, LocalizedError {
    case launchFailed(String)
    case timeout(seconds: TimeInterval)
    case nonZeroExit(status: Int32)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "osascript could not start: \(message)"
        case .timeout(let seconds):
            return "osascript timed out after \(seconds) seconds"
        case .nonZeroExit(let status):
            return "osascript exited with status \(status)"
        }
    }

    /// `osascript` and the controlled terminal host own stderr. Either can echo a
    /// script literal containing Ethan's transcript or native session identity, and
    /// this error is later shown and logged. Accept the bytes only to make their
    /// deliberate disposal testable; never retain or interpolate them.
    static func redactedNonZeroExit(
        status: Int32,
        untrustedStderr _: String
    ) -> Self {
        .nonZeroExit(status: status)
    }
}

/// Runs host-native Terminal/iTerm automation away from MainActor and kills the
/// helper at a hard deadline. Destination capture and delivery happen while the
/// recorder/delivery state machine is live; an unbounded NSAppleScript call there
/// could freeze every recorder panel or leave a late command targeting a stale PTY.
/// The source is sent over stdin, never argv or environment, because it can contain
/// Ethan's transcript.
enum BoundedAppleScriptRunner {
    static func run(
        source: String,
        timeout: TimeInterval
    ) async throws -> BoundedAppleScriptResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                execute(source: source, timeout: timeout, continuation: continuation)
            }
        }
    }

    private static func execute(
        source: String,
        timeout: TimeInterval,
        continuation: CheckedContinuation<BoundedAppleScriptResult, Error>
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        // Do not call ShellCommandEnvironment here. Its first-use login-shell PATH
        // discovery can block for multiple three-second attempts before `osascript`
        // even launches, defeating this runner's 1.5/2-second hard deadline. The
        // executable and every helper used by our scripts have absolute paths, so the
        // inherited process environment is sufficient and starts the bounded clock
        // immediately around the only external operation that matters.

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let output = AppleScriptDataBuffer()
        let errorOutput = AppleScriptDataBuffer()
        let drainGroup = DispatchGroup()
        drain(outputPipe.fileHandleForReading, into: output, group: drainGroup)
        drain(errorPipe.fileHandleForReading, into: errorOutput, group: drainGroup)

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }

        do {
            try process.run()
        } catch {
            try? inputPipe.fileHandleForWriting.close()
            continuation.resume(
                throwing: BoundedAppleScriptError.launchFailed(
                    error.localizedDescription
                )
            )
            return
        }

        let inputGroup = DispatchGroup()
        inputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                try? inputPipe.fileHandleForWriting.close()
                inputGroup.leave()
            }
            guard let data = source.data(using: .utf8) else { return }
            try? inputPipe.fileHandleForWriting.write(contentsOf: data)
        }

        guard termination.wait(timeout: .now() + timeout) == .success else {
            terminate(process, termination: termination)
            _ = inputGroup.wait(timeout: .now() + 1)
            _ = drainGroup.wait(timeout: .now() + 1)
            continuation.resume(
                throwing: BoundedAppleScriptError.timeout(seconds: timeout)
            )
            return
        }

        _ = inputGroup.wait(timeout: .now() + 1)
        _ = drainGroup.wait(timeout: .now() + 1)
        let stderr = errorOutput.stringValue()
        guard process.terminationStatus == 0 else {
            continuation.resume(
                throwing: BoundedAppleScriptError.redactedNonZeroExit(
                    status: process.terminationStatus,
                    untrustedStderr: stderr
                )
            )
            return
        }
        continuation.resume(
            returning: BoundedAppleScriptResult(
                stdout: output.stringValue()
            )
        )
    }

    private static func drain(
        _ handle: FileHandle,
        into buffer: AppleScriptDataBuffer,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                try? handle.close()
                group.leave()
            }
            buffer.append(handle.readDataToEndOfFile())
        }
    }

    private static func terminate(
        _ process: Process,
        termination: DispatchSemaphore
    ) {
        guard process.isRunning else { return }
        process.terminate()
        if termination.wait(timeout: .now() + 0.25) == .success { return }
        guard process.isRunning else { return }
        _ = kill(process.processIdentifier, SIGKILL)
        _ = termination.wait(timeout: .now() + 0.5)
    }
}

private final class AppleScriptDataBuffer {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func stringValue() -> String {
        lock.lock()
        let copy = data
        lock.unlock()
        return String(data: copy, encoding: .utf8) ?? ""
    }
}

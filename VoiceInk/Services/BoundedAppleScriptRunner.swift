import Darwin
import Foundation

struct BoundedAppleScriptResult {
    let stdout: String
}

enum BoundedAppleScriptOutputStream: String {
    case standardOutput = "stdout"
    case standardError = "stderr"
}

enum BoundedAppleScriptError: Error, LocalizedError {
    case invalidTimeout(maximumSeconds: TimeInterval)
    case sourceTooLarge(maximumBytes: Int)
    case launchFailed(String)
    case timeout(seconds: TimeInterval)
    case outputLimitExceeded(
        stream: BoundedAppleScriptOutputStream,
        maximumBytes: Int
    )
    case outputReadFailed
    case invalidUTF8Output
    case nonZeroExit(status: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidTimeout(let maximumSeconds):
            return "osascript timeout must be greater than zero and no more than \(maximumSeconds) seconds"
        case .sourceTooLarge(let maximumBytes):
            return "osascript source exceeded the \(maximumBytes)-byte safety limit"
        case .launchFailed(let message):
            return "osascript could not start: \(message)"
        case .timeout(let seconds):
            return "osascript timed out after \(seconds) seconds"
        case .outputLimitExceeded(let stream, let maximumBytes):
            return "osascript \(stream.rawValue) exceeded the \(maximumBytes)-byte safety limit"
        case .outputReadFailed:
            return "osascript output could not be read completely"
        case .invalidUTF8Output:
            return "osascript stdout was not valid UTF-8"
        case .nonZeroExit(let status):
            return "osascript exited with status \(status)"
        }
    }

    /// `osascript`, a terminal host, or a helper invoked by AppleScript can echo
    /// a script literal containing Ethan's transcript or terminal contents to
    /// stderr. Keep the parameter so redaction is directly regression-testable,
    /// but never retain or interpolate those untrusted diagnostics.
    static func redactedNonZeroExit(
        status: Int32,
        untrustedStderr _: String
    ) -> Self {
        .nonZeroExit(status: status)
    }
}

/// Runs the small host-native scripts used for exact Terminal/iTerm capture and
/// delivery without blocking MainActor. Script source travels only over stdin:
/// terminal text and session identifiers must never appear in argv, environment
/// values, shell interpolation, logs, or user-visible errors.
///
/// Production sources must keep terminal contents inside AppleScript and return
/// them directly through the bounded stdout frame. In particular, do not delegate
/// private payloads through `do shell script`: macOS can execute that work outside
/// the `osascript` process tree, defeating both payload isolation and cancellation.
///
/// The limits are deliberately fixed and conservative. Framed terminal results
/// contain only bounded tail buffers, so exceeding one is evidence that the host
/// contract failed rather than a reason to keep accumulating private scrollback.
enum BoundedAppleScriptRunner {
    static let maximumTimeout: TimeInterval = 30
    static let maximumSourceByteCount = 4 * 1_024 * 1_024
    static let maximumStandardOutputByteCount = 256 * 1_024
    static let maximumStandardErrorByteCount = 64 * 1_024

    static func run(
        source: String,
        timeout: TimeInterval
    ) async throws -> BoundedAppleScriptResult {
        guard timeout.isFinite,
              timeout > 0,
              timeout <= maximumTimeout else {
            throw BoundedAppleScriptError.invalidTimeout(
                maximumSeconds: maximumTimeout
            )
        }

        let invocation = BoundedAppleScriptInvocation(
            source: source,
            timeout: timeout
        )

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await invocation.start()
        } onCancel: {
            // Cancellation owns the helper immediately. Merely cancelling the
            // Swift task would otherwise allow a stale terminal mutation to land
            // after its recording session had already been replaced.
            invocation.cancel()
        }
    }
}

private final class BoundedAppleScriptInvocation: @unchecked Sendable {
    private enum Completion {
        case success(BoundedAppleScriptResult)
        case failure(Error)

        func resume(
            _ continuation: CheckedContinuation<BoundedAppleScriptResult, Error>
        ) {
            switch self {
            case .success(let result):
                continuation.resume(returning: result)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private enum ExecutionState {
        case active
        case terminated
        case completed
    }

    private struct Runtime {
        let process: Process
        let standardInput: ManagedFileHandle
        let standardOutput: ManagedFileHandle
        let standardError: ManagedFileHandle
        var didLaunch = false
        var didTerminate = false
    }

    private struct AbortPayload {
        let continuation: CheckedContinuation<BoundedAppleScriptResult, Error>?
        let runtime: Runtime?
    }

    private static let executionQueue = DispatchQueue(
        label: "com.ethansk.voiceink.bounded-applescript.execute",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let ioQueue = DispatchQueue(
        label: "com.ethansk.voiceink.bounded-applescript.io",
        qos: .utility,
        attributes: .concurrent
    )
    private static let terminationQueue = DispatchQueue(
        label: "com.ethansk.voiceink.bounded-applescript.terminate",
        qos: .userInitiated
    )

    private let source: String
    private let timeout: TimeInterval
    private let deadline: DispatchTime
    private let lock = NSLock()
    private let lifecycleSignal = DispatchSemaphore(value: 0)
    private let processTerminationSignal = DispatchSemaphore(value: 0)

    private var continuation: CheckedContinuation<BoundedAppleScriptResult, Error>?
    private var completion: Completion?
    private var runtime: Runtime?

    init(source: String, timeout: TimeInterval) {
        self.source = source
        self.timeout = timeout
        self.deadline = .now() + timeout
    }

    func start() async throws -> BoundedAppleScriptResult {
        try await withCheckedThrowingContinuation { continuation in
            if let immediateCompletion = install(continuation) {
                immediateCompletion.resume(continuation)
                return
            }

            // A separate monotonic deadline resolves the caller even if pipe
            // cleanup is slow. The worker also waits on this same absolute
            // deadline, so queueing time is included in the execution budget.
            Self.terminationQueue.asyncAfter(deadline: deadline) { [weak self] in
                self?.expire()
            }
            Self.executionQueue.async { [self] in
                execute()
            }
        }
    }

    func cancel() {
        abort(with: .failure(CancellationError()), unlessTerminated: false)
    }

    private func execute() {
        guard executionState() == .active else { return }

        // UTF-8 measurement and allocation can scale with the transcript. Keep
        // both off MainActor and inside the same hard execution deadline.
        guard source.utf8.count <= BoundedAppleScriptRunner.maximumSourceByteCount else {
            finish(
                .failure(
                    BoundedAppleScriptError.sourceTooLarge(
                        maximumBytes: BoundedAppleScriptRunner.maximumSourceByteCount
                    )
                )
            )
            return
        }
        let sourceData = Data(source.utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        // Use only fixed process metadata. In particular, do not call the shared
        // shell-environment builder and never place source, transcript text,
        // terminal contents, or session identity in an environment value.
        process.environment = Self.minimumEnvironment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let input = ManagedFileHandle(inputPipe.fileHandleForWriting)
        let output = ManagedFileHandle(outputPipe.fileHandleForReading)
        let stderrHandle = ManagedFileHandle(errorPipe.fileHandleForReading)
        let runtime = Runtime(
            process: process,
            standardInput: input,
            standardOutput: output,
            standardError: stderrHandle
        )

        guard register(runtime) else {
            Self.closeEveryEndpoint(
                inputPipe: inputPipe,
                outputPipe: outputPipe,
                errorPipe: errorPipe,
                input: input,
                output: output,
                error: stderrHandle
            )
            return
        }

        process.terminationHandler = { [weak self] _ in
            self?.markProcessTerminated()
        }

        do {
            guard try launchRegisteredProcess() else {
                Self.closeEveryEndpoint(
                    inputPipe: inputPipe,
                    outputPipe: outputPipe,
                    errorPipe: errorPipe,
                    input: input,
                    output: output,
                    error: stderrHandle
                )
                return
            }
        } catch {
            Self.closeEveryEndpoint(
                inputPipe: inputPipe,
                outputPipe: outputPipe,
                errorPipe: errorPipe,
                input: input,
                output: output,
                error: stderrHandle
            )
            finish(
                .failure(
                    BoundedAppleScriptError.launchFailed(
                        error.localizedDescription
                    )
                )
            )
            return
        }

        // Close only the parent's unused endpoints after spawn. The child owns
        // duplicated descriptors, while these closes are what let our drains see
        // EOF promptly when the helper exits.
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        let stdout = BoundedDataCollector(
            limit: BoundedAppleScriptRunner.maximumStandardOutputByteCount
        )
        let stderr = BoundedDataCollector(
            limit: BoundedAppleScriptRunner.maximumStandardErrorByteCount
        )
        let drainGroup = DispatchGroup()
        startDrain(output, into: stdout, group: drainGroup)
        startDrain(stderrHandle, into: stderr, group: drainGroup)

        let inputGroup = DispatchGroup()
        startWriting(sourceData, to: input, group: inputGroup)

        waitForProcessOrAbort()

        switch executionState() {
        case .completed:
            // Timeout/cancellation already resolved the async caller and initiated
            // TERM/KILL. Cleanup remains bounded and cannot deliver another result.
            _ = processTerminationSignal.wait(timeout: .now() + 0.4)
            input.close()
            output.close()
            stderrHandle.close()
            _ = inputGroup.wait(timeout: .now() + 0.1)
            _ = drainGroup.wait(timeout: .now() + 0.1)
            return

        case .active:
            // A wait can expire just before the dedicated deadline block executes.
            // Resolve that race through the same one-shot timeout path.
            expire()
            _ = processTerminationSignal.wait(timeout: .now() + 0.4)
            input.close()
            output.close()
            stderrHandle.close()
            _ = inputGroup.wait(timeout: .now() + 0.1)
            _ = drainGroup.wait(timeout: .now() + 0.1)
            return

        case .terminated:
            break
        }

        input.close()
        _ = inputGroup.wait(timeout: .now() + 0.1)

        let drainDeadline = DispatchTime.now() + 0.5
        guard drainGroup.wait(timeout: drainDeadline) == .success else {
            output.close()
            stderrHandle.close()
            _ = drainGroup.wait(timeout: .now() + 0.1)
            finish(.failure(BoundedAppleScriptError.outputReadFailed))
            return
        }

        guard !stdout.didReadFail,
              !stderr.didReadFail else {
            finish(.failure(BoundedAppleScriptError.outputReadFailed))
            return
        }

        let stdoutSnapshot = stdout.snapshot()
        let stderrSnapshot = stderr.snapshot()
        let status = process.terminationStatus

        // Stderr is untrusted and may contain an AppleScript literal. On failure,
        // use it only as a bounded argument to the testable redaction boundary.
        guard status == 0 else {
            let untrustedStderr = String(
                decoding: stderrSnapshot.data,
                as: UTF8.self
            )
            finish(
                .failure(
                    BoundedAppleScriptError.redactedNonZeroExit(
                        status: status,
                        untrustedStderr: untrustedStderr
                    )
                )
            )
            return
        }

        if stdoutSnapshot.didOverflow {
            finish(
                .failure(
                    BoundedAppleScriptError.outputLimitExceeded(
                        stream: .standardOutput,
                        maximumBytes: BoundedAppleScriptRunner
                            .maximumStandardOutputByteCount
                    )
                )
            )
            return
        }
        if stderrSnapshot.didOverflow {
            finish(
                .failure(
                    BoundedAppleScriptError.outputLimitExceeded(
                        stream: .standardError,
                        maximumBytes: BoundedAppleScriptRunner
                            .maximumStandardErrorByteCount
                    )
                )
            )
            return
        }
        guard let value = String(
            data: stdoutSnapshot.data,
            encoding: .utf8
        ) else {
            finish(.failure(BoundedAppleScriptError.invalidUTF8Output))
            return
        }

        finish(.success(BoundedAppleScriptResult(stdout: value)))
    }

    private func install(
        _ continuation: CheckedContinuation<BoundedAppleScriptResult, Error>
    ) -> Completion? {
        lock.lock()
        defer { lock.unlock() }

        if let completion {
            return completion
        }
        self.continuation = continuation
        return nil
    }

    private func register(_ runtime: Runtime) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard completion == nil else { return false }
        self.runtime = runtime
        return true
    }

    /// Serialize launch against cancellation/expiry. `Process.run()` performs only
    /// the local spawn here; all AppleScript execution remains outside the lock and
    /// under the monotonic deadline. This closes the dangerous race where a task is
    /// cancelled just before a not-yet-launched helper starts with stale source.
    private func launchRegisteredProcess() throws -> Bool {
        lock.lock()
        guard completion == nil,
              var runtime else {
            lock.unlock()
            return false
        }

        do {
            try runtime.process.run()
            runtime.didLaunch = true
            self.runtime = runtime
            lock.unlock()
            return true
        } catch {
            lock.unlock()
            throw error
        }
    }

    private func markProcessTerminated() {
        lock.lock()
        if var runtime {
            runtime.didTerminate = true
            self.runtime = runtime
        }
        lock.unlock()

        processTerminationSignal.signal()
        lifecycleSignal.signal()
    }

    private func waitForProcessOrAbort() {
        if lifecycleSignal.wait(timeout: deadline) == .timedOut {
            expire()
        }
    }

    private func executionState() -> ExecutionState {
        lock.lock()
        defer { lock.unlock() }

        if completion != nil {
            return .completed
        }
        if runtime?.didTerminate == true {
            return .terminated
        }
        return .active
    }

    private func expire() {
        abort(
            with: .failure(
                BoundedAppleScriptError.timeout(seconds: timeout)
            ),
            unlessTerminated: true
        )
    }

    private func finish(_ completion: Completion) {
        let continuation: CheckedContinuation<BoundedAppleScriptResult, Error>?

        lock.lock()
        guard self.completion == nil else {
            lock.unlock()
            return
        }
        self.completion = completion
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation.map(completion.resume)
        lifecycleSignal.signal()
    }

    private func abort(
        with completion: Completion,
        unlessTerminated: Bool
    ) {
        let payload: AbortPayload

        lock.lock()
        guard self.completion == nil,
              !(unlessTerminated && runtime?.didTerminate == true) else {
            lock.unlock()
            return
        }
        self.completion = completion
        payload = AbortPayload(
            continuation: continuation,
            runtime: runtime
        )
        continuation = nil
        lock.unlock()

        // Closing stdin first prevents any blocked writer from feeding more source.
        // TERM is immediate and KILL is scheduled after a short, fixed grace period;
        // no caller or cleanup queue waits indefinitely for a misbehaving helper.
        payload.runtime?.standardInput.close()
        if let runtime = payload.runtime,
           runtime.didLaunch,
           !runtime.didTerminate {
            Self.terminate(runtime.process)
        }
        payload.runtime?.standardOutput.close()
        payload.runtime?.standardError.close()

        payload.continuation.map(completion.resume)
        lifecycleSignal.signal()
    }

    private func startWriting(
        _ data: Data,
        to endpoint: ManagedFileHandle,
        group: DispatchGroup
    ) {
        group.enter()
        Self.ioQueue.async { [weak self] in
            defer {
                endpoint.close()
                group.leave()
            }

            var offset = 0
            let chunkSize = 16 * 1_024
            while offset < data.count {
                guard self?.executionState() == .active else { return }
                let end = min(offset + chunkSize, data.count)
                do {
                    try endpoint.handle.write(
                        contentsOf: data.subdata(in: offset..<end)
                    )
                } catch {
                    // Early helper exit, timeout, and cancellation all close stdin.
                    // Its final status or the already-recorded abort owns the result.
                    return
                }
                offset = end
            }
        }
    }

    private func startDrain(
        _ endpoint: ManagedFileHandle,
        into collector: BoundedDataCollector,
        group: DispatchGroup
    ) {
        group.enter()
        Self.ioQueue.async {
            defer {
                endpoint.close()
                group.leave()
            }

            do {
                while let data = try endpoint.handle.read(upToCount: 16 * 1_024),
                      !data.isEmpty {
                    // Keep draining after the cap so a verbose helper cannot fill a
                    // pipe and deadlock itself; only retained bytes are bounded.
                    collector.append(data)
                }
            } catch {
                collector.markReadFailed()
            }
        }
    }

    private static var minimumEnvironment: [String: String] {
        [
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8"
        ]
    }

    private static func closeEveryEndpoint(
        inputPipe: Pipe,
        outputPipe: Pipe,
        errorPipe: Pipe,
        input: ManagedFileHandle,
        output: ManagedFileHandle,
        error: ManagedFileHandle
    ) {
        input.close()
        output.close()
        error.close()
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
    }

    /// Ask `osascript` to stop, then escalate once after a short fixed grace period.
    /// Production sources never use `do shell script`: macOS can delegate that work
    /// outside this helper, where terminating `osascript` cannot revoke it safely.
    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }

        process.terminate()
        terminationQueue.asyncAfter(deadline: .now() + 0.15) {
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

private final class ManagedFileHandle {
    let handle: FileHandle

    private let lock = NSLock()
    private var isClosed = false

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        lock.unlock()
        try? handle.close()
    }
}

private final class BoundedDataCollector {
    struct Snapshot {
        let data: Data
        let didOverflow: Bool
    }

    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var overflowed = false
    private var readFailed = false

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }

        lock.lock()
        let availableByteCount = max(0, limit - data.count)
        if availableByteCount > 0 {
            data.append(newData.prefix(availableByteCount))
        }
        if newData.count > availableByteCount {
            overflowed = true
        }
        lock.unlock()
    }

    func markReadFailed() {
        lock.lock()
        readFailed = true
        lock.unlock()
    }

    var didReadFail: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readFailed
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(data: data, didOverflow: overflowed)
    }
}

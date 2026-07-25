import Foundation

// The real FactoryTooling: spawns `git`/`gh` with an absolute path,
// drains stdout/stderr concurrently (a full pipe buffer would
// otherwise deadlock the child), enforces a hard timeout, and honours
// task cancellation. Interactive prompts are disabled so a missing
// credential can never wedge the app.

public struct ProcessTooling: FactoryTooling {
    let locator: ToolLocator

    public init(locator: ToolLocator) {
        self.locator = locator
    }

    public init() {
        self.locator = .resolve()
    }

    public func run(_ tool: FactoryTool,
                    _ arguments: [String],
                    workingDirectory: URL?,
                    timeout: Duration) async throws -> ProcessResult {
        guard let executable = locator.path(for: tool) else {
            throw ToolingError.toolNotFound(tool)
        }
        let runner = ProcessRunner(tool: tool)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                runner.start(executable: executable,
                             arguments: arguments,
                             workingDirectory: workingDirectory,
                             environment: environment(),
                             timeout: timeout,
                             continuation: continuation)
            }
        } onCancel: {
            runner.cancel()
        }
    }

    /// A minimal, explicit child environment. Inherit HOME (gh reads
    /// ~/.config/gh) but pin PATH to the tool dirs so gh's own git
    /// resolves, and disable every interactive prompt.
    private func environment() -> [String: String] {
        var env: [String: String] = [
            "PATH": locator.searchDirectories.joined(separator: ":"),
            "GIT_TERMINAL_PROMPT": "0",
            "GH_PROMPT_DISABLED": "1",
            "GH_NO_UPDATE_NOTIFIER": "1",
            "CLICOLOR": "0",
        ]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK", "XDG_CONFIG_HOME"] {
            if let value = ProcessInfo.processInfo.environment[key] {
                env[key] = value
            }
        }
        return env
    }
}

/// Bridges Process's callback API into one async result. State is
/// guarded by a lock and the continuation is resumed exactly once, so
/// the class is safely Sendable despite wrapping non-Sendable
/// Process/Pipe internals (they never escape this object).
private final class ProcessRunner: @unchecked Sendable {
    private let tool: FactoryTool
    private let lock = NSLock()
    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()

    private var stdout = Data()
    private var stderr = Data()
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    init(tool: FactoryTool) {
        self.tool = tool
    }

    func start(executable: String,
               arguments: [String],
               workingDirectory: URL?,
               environment: [String: String],
               timeout: Duration,
               continuation: CheckedContinuation<ProcessResult, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain each pipe on its own thread with a blocking read to
        // EOF — NOT readabilityHandler. A handler runs on a shared
        // queue and can fire concurrently with completion tearing the
        // FileHandle down; FileHandle is not thread-safe, so that race
        // corrupted the heap and crashed later in unrelated code (GRDB
        // string binds). Blocking reads own the handle for their whole
        // life, and completion only reads the resulting Data under the
        // lock — no shared FileHandle access, no race.
        let group = DispatchGroup()
        drain(outPipe, isStdout: true, group: group)
        drain(errPipe, isStdout: false, group: group)

        do {
            try process.run()
        } catch {
            // Child never started; close the write ends so the reader
            // threads hit EOF and don't block forever.
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            resume(.failure(ToolingError.spawnFailed(tool, error.localizedDescription)))
            return
        }

        // Both readers reach EOF once the child exits and closes its
        // pipe ends — the natural "process is done and fully drained"
        // signal for the success path.
        group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
            self?.complete(with: nil)
        }

        let tool = self.tool
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.complete(with: .timedOut(tool))
        }
        // Install under the lock so it can't race a completion that
        // already happened for a fast-exiting child.
        lock.lock()
        if finished {
            lock.unlock()
            watchdog.cancel()
        } else {
            timeoutTask = watchdog
            lock.unlock()
        }
    }

    func cancel() {
        complete(with: .cancelled)
    }

    /// Read a pipe to EOF on a background thread, storing the result
    /// under the lock. `group` tracks completion of both readers.
    private func drain(_ pipe: Pipe, isStdout: Bool, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let self {
                self.lock.lock()
                if isStdout { self.stdout = data } else { self.stderr = data }
                self.lock.unlock()
            }
            group.leave()
        }
    }

    /// Finalise once. `error != nil` means timeout/cancel — terminate
    /// the still-running child (its EOF then fires the success path,
    /// which is ignored by the `finished` guard). The success path is
    /// only reached via `group.notify`, so both readers have finished
    /// and stdout/stderr are complete.
    private func complete(with error: ToolingError?) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let cont = continuation
        continuation = nil
        let task = timeoutTask
        timeoutTask = nil
        lock.unlock()

        task?.cancel()

        if error != nil, process.isRunning {
            process.terminate()
        }

        guard let cont else { return }
        if let error {
            cont.resume(throwing: error)
        } else {
            process.waitUntilExit()   // ensure terminationStatus is reaped
            lock.lock()
            let out = stdout
            let err = String(decoding: stderr, as: UTF8.self)
            lock.unlock()
            cont.resume(returning: ProcessResult(
                exitCode: process.terminationStatus, stdout: out, stderr: err))
        }
    }

    private func resume(_ result: Result<ProcessResult, Error>) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        switch result {
        case .success(let value): cont?.resume(returning: value)
        case .failure(let error): cont?.resume(throwing: error)
        }
    }
}

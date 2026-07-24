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

        // Drain both pipes as data arrives — synchronous appends under
        // the lock preserve byte order.
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.appendStdout(chunk)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.appendStderr(chunk)
        }

        process.terminationHandler = { [weak self] _ in
            self?.complete(with: nil)
        }

        do {
            try process.run()
        } catch {
            resume(.failure(ToolingError.spawnFailed(tool, error.localizedDescription)))
            return
        }

        let tool = self.tool
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.complete(with: .timedOut(tool))
        }
    }

    func cancel() {
        complete(with: .cancelled)
    }

    private func appendStdout(_ chunk: Data) {
        lock.lock(); stdout.append(chunk); lock.unlock()
    }

    private func appendStderr(_ chunk: Data) {
        lock.lock(); stderr.append(chunk); lock.unlock()
    }

    /// Finalise once: drain any remaining buffered output, tear down
    /// handlers, and resume the continuation. `error != nil` means
    /// timeout/cancel — terminate the still-running child first.
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

        // Flush whatever is left in the pipes, then detach handlers.
        let restOut = outPipe.fileHandleForReading.readabilityHandler
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        _ = restOut
        if let tail = try? outPipe.fileHandleForReading.readToEnd(), !tail.isEmpty {
            appendStdout(tail)
        }
        if let tail = try? errPipe.fileHandleForReading.readToEnd(), !tail.isEmpty {
            appendStderr(tail)
        }

        guard let cont else { return }
        if let error {
            cont.resume(throwing: error)
        } else {
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

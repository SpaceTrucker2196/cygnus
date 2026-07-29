import Foundation

// A subprocess whose output streams out line-by-line, live, so the CI
// Flow view can animate a build as it happens. Unlike ProcessTooling
// (which buffers to EOF for a single result), this yields each line as
// it arrives via an AsyncStream.
//
// Safety mirrors ProcessTooling's hard-won lesson: exactly ONE thread
// owns the read handle for its whole life, doing blocking reads — never
// a readabilityHandler, which races FileHandle teardown and corrupts
// the heap. stdout and stderr share one pipe so a single drain thread
// serialises everything.

public enum BuildEvent: Sendable, Equatable {
    case line(String)
    case finished(exitCode: Int32)
    case failed(String)   // the child never started
}

public final class BuildStreamRunner: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let pipe = Pipe()
    private var buffer = Data()
    private var terminated = false

    public init() {}

    /// Spawn `executable arguments` in `workingDirectory` and stream its
    /// combined output. The stream ends with `.finished` (or `.failed`
    /// if the child never launched). Cancelling the consuming task, or
    /// calling `cancel()`, terminates the child.
    public func stream(executable: String,
                       arguments: [String],
                       workingDirectory: URL,
                       environment: [String: String]) -> AsyncStream<BuildEvent> {
        AsyncStream { continuation in
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = pipe

            let readHandle = pipe.fileHandleForReading
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { continuation.finish(); return }
                while true {
                    let chunk = readHandle.availableData
                    if chunk.isEmpty { break }   // EOF: all write ends closed
                    self.lock.lock()
                    self.buffer.append(chunk)
                    let lines = self.drainLines()
                    self.lock.unlock()
                    for line in lines { continuation.yield(.line(line)) }
                }
                // Emit any trailing partial line, then the exit code.
                self.lock.lock()
                let tail = String(decoding: self.buffer, as: UTF8.self)
                self.buffer.removeAll()
                self.lock.unlock()
                if !tail.isEmpty { continuation.yield(.line(tail)) }
                self.process.waitUntilExit()
                continuation.yield(.finished(exitCode: self.process.terminationStatus))
                continuation.finish()
            }

            do {
                try process.run()
                // Close the parent's copy of the write end so the reader
                // sees EOF once the child exits (the child kept its dup).
                try? pipe.fileHandleForWriting.close()
            } catch {
                try? pipe.fileHandleForWriting.close()
                continuation.yield(.failed(error.localizedDescription))
                continuation.finish()
                return
            }

            continuation.onTermination = { @Sendable [weak self] _ in
                self?.cancel()
            }
        }
    }

    /// Split complete lines out of the buffer. Caller holds the lock.
    private func drainLines() -> [String] {
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let slice = buffer[buffer.startIndex..<newline]
            lines.append(String(decoding: slice, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }

    public func cancel() {
        lock.lock()
        let shouldKill = !terminated && process.isRunning
        terminated = true
        lock.unlock()
        if shouldKill { process.terminate() }
    }
}

import Foundation

// The seam between the ops dashboard and the outside world: the user's
// `git` and `gh` CLIs. Everything that shells out goes through this
// protocol so the whole factory layer is testable with a fake (see
// FixtureTooling in Tests/) — no network, no real binaries.

/// A command-line tool the dashboard drives.
public enum FactoryTool: String, Sendable, CaseIterable {
    case git
    case gh
    case swift
    case make
}

/// The result of one subprocess invocation. Sendable so it can cross
/// back to the caller's actor; the Process/Pipe that produced it never
/// escape ProcessTooling.
public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: String

    public init(exitCode: Int32, stdout: Data, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 }
}

/// Why a tool invocation could not produce a usable result. Views turn
/// these into actionable messages ("run `gh auth login`").
public enum ToolingError: Error, Sendable, Equatable {
    case toolNotFound(FactoryTool)
    case notAuthenticated(FactoryTool)
    case timedOut(FactoryTool)
    case spawnFailed(FactoryTool, String)
    case nonZeroExit(FactoryTool, code: Int32, stderr: String)
    case cancelled
}

/// What the factory providers need to run a tool. Injected so tests
/// substitute a deterministic fake.
public protocol FactoryTooling: Sendable {
    /// Run `tool arguments` in `workingDirectory`, killing it after
    /// `timeout`. Returns the raw result even for non-zero exit — the
    /// caller decides whether a non-zero code is an error (e.g. `gh
    /// issue list` on a repo with zero issues still exits 0, but `git
    /// remote get-url origin` legitimately exits non-zero).
    func run(_ tool: FactoryTool,
             _ arguments: [String],
             workingDirectory: URL?,
             timeout: Duration) async throws -> ProcessResult
}

extension FactoryTooling {
    /// Convenience: run and throw `nonZeroExit` on a non-zero code,
    /// mapping recognisable `gh` auth failures to `.notAuthenticated`.
    public func runChecked(_ tool: FactoryTool,
                           _ arguments: [String],
                           workingDirectory: URL?,
                           timeout: Duration = .seconds(30)) async throws -> ProcessResult {
        let result = try await run(tool, arguments,
                                   workingDirectory: workingDirectory, timeout: timeout)
        guard result.succeeded else {
            if tool == .gh, Self.looksUnauthenticated(result.stderr) {
                throw ToolingError.notAuthenticated(.gh)
            }
            throw ToolingError.nonZeroExit(tool, code: result.exitCode, stderr: result.stderr)
        }
        return result
    }

    static func looksUnauthenticated(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("gh auth login")
            || lowered.contains("not logged")
            || lowered.contains("authentication required")
            || lowered.contains("http 401")
    }
}

import Foundation
@testable import CygnusKit

// Deterministic FactoryTooling for tests: match an invocation by
// (tool, argument-prefix) and return canned output. Records every call
// so tests can assert the exact CLI arguments the providers issued —
// no network, no real binaries.

final class FixtureTooling: FactoryTooling, @unchecked Sendable {
    struct Stub {
        let tool: FactoryTool
        let argsPrefix: [String]
        let result: Result<ProcessResult, ToolingError>
    }

    struct Invocation: Equatable {
        let tool: FactoryTool
        let arguments: [String]
        let workingDirectory: URL?
    }

    private let lock = NSLock()
    private var stubs: [Stub] = []
    private(set) var invocations: [Invocation] = []

    init() {}

    // MARK: Stubbing

    @discardableResult
    func stub(_ tool: FactoryTool, argsPrefix: [String],
              stdout: String = "", stderr: String = "", exitCode: Int32 = 0) -> Self {
        let result = ProcessResult(exitCode: exitCode,
                                   stdout: Data(stdout.utf8), stderr: stderr)
        lock.lock()
        stubs.append(Stub(tool: tool, argsPrefix: argsPrefix, result: .success(result)))
        lock.unlock()
        return self
    }

    @discardableResult
    func stubError(_ tool: FactoryTool, argsPrefix: [String], error: ToolingError) -> Self {
        lock.lock()
        stubs.append(Stub(tool: tool, argsPrefix: argsPrefix, result: .failure(error)))
        lock.unlock()
        return self
    }

    // MARK: FactoryTooling

    func run(_ tool: FactoryTool, _ arguments: [String],
             workingDirectory: URL?, timeout: Duration) async throws -> ProcessResult {
        let match: Stub? = lock.withLock {
            invocations.append(Invocation(tool: tool, arguments: arguments,
                                          workingDirectory: workingDirectory))
            return stubs.first { stub in
                stub.tool == tool && arguments.starts(with: stub.argsPrefix)
            }
        }
        guard let match else {
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: "")
        }
        switch match.result {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }

    // MARK: Assertions helpers

    func invoked(_ tool: FactoryTool, argsPrefix: [String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return invocations.contains { $0.tool == tool && $0.arguments.starts(with: argsPrefix) }
    }
}

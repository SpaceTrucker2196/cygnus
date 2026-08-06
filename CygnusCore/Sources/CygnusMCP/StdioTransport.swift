import Foundation

// Newline-delimited JSON on stdio — one object per line.
//
// NOT LSP's `Content-Length` framing, which is the single most common
// way to write an MCP server that never completes a handshake. Stdio
// also means no socket and no network entitlement: the process talks
// to its parent and to nothing else.
//
// stdout carries protocol messages and nothing else. Every diagnostic
// goes to stderr, because one stray `print` corrupts the stream
// permanently — which is also why this ships as its own executable
// rather than a `cygnus` subcommand, since that CLI prints progress to
// stdout unconditionally.

public protocol MessageTransport: Sendable {
    /// Next line, or nil at end of input.
    func readLine() throws -> String?
    func write(_ line: String) throws
    func log(_ message: String)
}

public struct StdioTransport: MessageTransport {
    private let input: FileHandle
    private let output: FileHandle
    private let errors: FileHandle

    public init(input: FileHandle = .standardInput,
                output: FileHandle = .standardOutput,
                errors: FileHandle = .standardError) {
        self.input = input
        self.output = output
        self.errors = errors
    }

    public func readLine() throws -> String? {
        var buffer = Data()
        while true {
            guard let chunk = try input.read(upToCount: 1), !chunk.isEmpty else {
                return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
            }
            if chunk[0] == 0x0A {   // \n
                return String(decoding: buffer, as: UTF8.self)
            }
            buffer.append(chunk)
        }
    }

    public func write(_ line: String) throws {
        try output.write(contentsOf: Data((line + "\n").utf8))
    }

    public func log(_ message: String) {
        try? errors.write(contentsOf: Data((message + "\n").utf8))
    }
}

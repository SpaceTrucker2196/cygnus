import Foundation

// The protocol loop. Handshake, dispatch, and nothing else.
//
// An actor because the workspace behind it is one, and because a
// malformed message must never be able to leave the server in a state
// where the next well-formed one is answered wrongly.

public actor MCPServer {
    /// Versions this server understands. A client asking for one of
    /// these gets it echoed back; anything else is answered with our
    /// newest, which the spec permits and clients handle.
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let preferredVersion = "2025-06-18"

    private let transport: any MessageTransport
    private let handlers: ToolHandlers
    private var initialized = false

    public init(transport: any MessageTransport, handlers: ToolHandlers) {
        self.transport = transport
        self.handlers = handlers
    }

    /// Read until end of input. One malformed line is answered with a
    /// parse error and the loop continues — a client that sends
    /// garbage should not take the session down.
    public func run() async {
        while let line = try? transport.readLine() {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let response = await handle(line: line) {
                try? transport.write(response)
            }
        }
    }

    /// Returns the response line, or nil for notifications, which the
    /// spec says must never be answered.
    func handle(line: String) async -> String? {
        let decoder = JSONDecoder()
        guard let data = line.data(using: .utf8),
              let request = try? decoder.decode(JSONRPCRequest.self, from: data) else {
            return encode(.failure(id: nil, error: .parseError))
        }
        guard request.jsonrpc == "2.0" else {
            return encode(.failure(id: request.id, error: .invalidRequest))
        }

        // Notification: act, answer nothing.
        guard let id = request.id else {
            if request.method == "notifications/initialized" { initialized = true }
            return nil
        }

        do {
            let result = try await dispatch(method: request.method, params: request.params)
            return encode(.success(id: id, result: result))
        } catch let error as JSONRPCError {
            return encode(.failure(id: id, error: error))
        } catch {
            return encode(.failure(id: id, error: .internalError("\(error)")))
        }
    }

    private func dispatch(method: String, params: JSONValue?) async throws -> JSONValue {
        switch method {
        case "initialize":
            let requested = params?.objectValue?["protocolVersion"]?.stringValue
            let version = requested.flatMap {
                Self.supportedVersions.contains($0) ? $0 : nil
            } ?? Self.preferredVersion
            initialized = true
            return .object([
                "protocolVersion": .string(version),
                // Advertise nothing that isn't implemented: no
                // resources, no prompts, no logging.
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": .string("cygnus"),
                    "version": .string("0.1.0"),
                ]),
            ])

        case "ping":
            return .object([:])

        case "tools/list":
            try requireInitialized()
            return ToolCatalog.listing

        case "tools/call":
            try requireInitialized()
            guard let object = params?.objectValue,
                  let name = object["name"]?.stringValue else {
                throw JSONRPCError.invalidParams("name is required")
            }
            let arguments = object["arguments"]?.objectValue ?? [:]
            do {
                let text = try await handlers.call(name, arguments: arguments)
                return .object([
                    "content": .array([
                        .object(["type": .string("text"), "text": .string(text)]),
                    ]),
                    "isError": .bool(false),
                ])
            } catch let error as JSONRPCError {
                throw error
            } catch {
                // A tool that fails is a tool result, not a protocol
                // error — the agent should see the reason and be able
                // to try something else.
                return .object([
                    "content": .array([
                        .object(["type": .string("text"),
                                 "text": .string("\(name) failed: \(error)")]),
                    ]),
                    "isError": .bool(true),
                ])
            }

        default:
            throw JSONRPCError.methodNotFound(method)
        }
    }

    private func requireInitialized() throws {
        guard initialized else {
            throw JSONRPCError(code: -32002, message: "Server not initialized")
        }
    }

    private func encode(_ response: JSONRPCResponse) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(response) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"encoding failed"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}

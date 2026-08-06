import Testing
import Foundation
@testable import CygnusMCP

// Protocol conformance, driven over an in-memory pipe rather than a
// subprocess. The failures these catch are the ones that make a server
// silently never work: an id echoed back with the wrong type, an
// answered notification, a malformed line killing the loop.

/// Records what the server wrote, and feeds it scripted input.
final class FakeTransport: MessageTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String]
    private(set) var written: [String] = []
    private(set) var logged: [String] = []

    init(input: [String] = []) { self.pending = input }

    func readLine() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    func write(_ line: String) throws {
        lock.lock(); defer { lock.unlock() }
        written.append(line)
    }

    func log(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        logged.append(message)
    }
}

@Suite struct ProtocolTests {
    private func server(_ transport: FakeTransport) async throws -> MCPServer {
        MCPServer(transport: transport, handlers: try await Fixtures.handlers())
    }

    private func json(_ line: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(
            with: Data(line.utf8)) as? [String: Any])
    }

    @Test func initializeEchoesARecognisedProtocolVersion() async throws {
        let transport = FakeTransport()
        let server = try await server(transport)
        let response = try #require(await server.handle(line: """
            {"jsonrpc":"2.0","id":1,"method":"initialize",\
            "params":{"protocolVersion":"2024-11-05"}}
            """))
        let object = try json(response)
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2024-11-05")
    }

    @Test func anUnknownProtocolVersionFallsBackToOurs() async throws {
        let transport = FakeTransport()
        let server = try await server(transport)
        let response = try #require(await server.handle(line: """
            {"jsonrpc":"2.0","id":1,"method":"initialize",\
            "params":{"protocolVersion":"1999-01-01"}}
            """))
        let result = try #require(try json(response)["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == MCPServer.preferredVersion)
    }

    /// Advertising a capability that isn't implemented is how clients
    /// end up calling methods that return -32601.
    @Test func onlyToolsAreAdvertised() async throws {
        let transport = FakeTransport()
        let server = try await server(transport)
        let response = try #require(await server.handle(
            line: #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#))
        let result = try #require(try json(response)["result"] as? [String: Any])
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        #expect(capabilities["tools"] != nil)
        #expect(capabilities["resources"] == nil)
        #expect(capabilities["prompts"] == nil)
    }

    /// A string id must come back as a string. Normalizing it to a
    /// number is a real interop bug and an easy one to ship.
    @Test func stringIdsAreEchoedAsStrings() async throws {
        let transport = FakeTransport()
        let server = try await server(transport)
        let response = try #require(await server.handle(
            line: #"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#))
        #expect(try json(response)["id"] as? String == "abc")
    }

    /// Notifications have no id and must never be answered.
    @Test func notificationsAreNotAnswered() async throws {
        let transport = FakeTransport()
        let server = try await server(transport)
        let response = await server.handle(
            line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(response == nil)
    }

    @Test func unknownMethodsReturnMethodNotFound() async throws {
        let transport = FakeTransport()
        let server = try await server(transport)
        _ = await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
        let response = try #require(await server.handle(
            line: #"{"jsonrpc":"2.0","id":2,"method":"nope"}"#))
        let error = try #require(try json(response)["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32601)
    }

    /// Garbage in must not take the session down.
    @Test func malformedJSONIsAParseErrorAndTheLoopSurvives() async throws {
        let transport = FakeTransport(input: [
            "{not json at all",
            #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
        ])
        let server = try await server(transport)
        await server.run()
        #expect(transport.written.count == 2)
        let first = try json(transport.written[0])
        #expect((first["error"] as? [String: Any])?["code"] as? Int == -32700)
        #expect(try json(transport.written[1])["result"] != nil)
    }

    @Test func toolsCannotBeCalledBeforeInitialize() async throws {
        let transport = FakeTransport()
        let server = try await server(transport)
        let response = try #require(await server.handle(
            line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        let error = try #require(try json(response)["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32002)
    }

    @Test func everyToolIsListedWithASchema() async throws {
        let transport = FakeTransport()
        let server = try await server(transport)
        _ = await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
        let response = try #require(await server.handle(
            line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let result = try #require(try json(response)["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(tools.count == ToolCatalog.tools.count)
        for tool in tools {
            #expect((tool["name"] as? String)?.isEmpty == false)
            #expect((tool["description"] as? String)?.isEmpty == false)
            #expect(tool["inputSchema"] != nil)
        }
    }

    /// A failing tool is a tool *result*, not a protocol error — the
    /// agent should see why and be able to try something else.
    @Test func aFailingToolReportsIsErrorRatherThanBreakingTheProtocol() async throws {
        let transport = FakeTransport()
        let server = try await server(transport)
        _ = await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
        let response = try #require(await server.handle(line: """
            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":\
            {"name":"cygnus_read_span","arguments":\
            {"path":"nope.swift","start_line":1,"end_line":2}}}
            """))
        let result = try #require(try json(response)["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
    }
}

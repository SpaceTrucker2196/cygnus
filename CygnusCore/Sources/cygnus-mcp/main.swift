import Foundation
import CygnusEngine
import CygnusProviders
import CygnusMCP

// The MCP entry point.
//
// A separate executable rather than a `cygnus mcp` subcommand, for one
// unglamorous reason: the CLI prints progress to stdout, and on this
// transport stdout is the protocol. One stray `print` corrupts the
// stream for the rest of the session. Keeping them apart makes that
// mistake impossible rather than merely discouraged.
//
// Wire it up in .mcp.json:
//   { "mcpServers": { "cygnus": {
//       "command": "/path/to/cygnus-mcp",
//       "env": { "CYGNUS_WORKSPACE": "/path/to/workspace" } } } }

func workspaceDirectory() -> URL {
    if let override = ProcessInfo.processInfo.environment["CYGNUS_WORKSPACE"] {
        return URL(fileURLWithPath: override)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cygnus/workspaces/default")
}

let transport = StdioTransport()
let directory = workspaceDirectory()

do {
    let workspace = try CygnusWorkspace(directory: directory)
    let contentStore = try ContentStore(root: directory.appendingPathComponent("cas"))
    let server = MCPServer(
        transport: transport,
        handlers: ToolHandlers(workspace: workspace, contentStore: contentStore))
    transport.log("cygnus-mcp: workspace \(directory.path)")
    await server.run()
} catch {
    // Diagnostics to stderr, always — stdout belongs to the protocol.
    transport.log("cygnus-mcp: failed to open workspace at \(directory.path): \(error)")
    exit(1)
}

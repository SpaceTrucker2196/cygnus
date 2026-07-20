import Foundation
import CygnusGraph
import CygnusEngine
import CygnusStore
import CygnusQuery

// CLI harness — the fastest way to exercise the engine without the
// app. Workspace location: $CYGNUS_WORKSPACE or the default under
// Application Support.

let usage = """
cygnus \(CygnusEngineInfo.version) — repository knowledge graph engine

usage: cygnus <command>

commands:
  register <path>    register a repository in the workspace
  repos              list registered repositories
  index              snapshot + analyze all registered repositories
  query contains     print the containment tree
  query deps         print the import graph
  revisions          list graph revisions
  bench              interval-schema storage benchmark
"""

func workspaceDirectory() -> URL {
    if let override = ProcessInfo.processInfo.environment["CYGNUS_WORKSPACE"] {
        return URL(fileURLWithPath: override)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cygnus/workspaces/default")
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "register":
    guard arguments.count >= 2 else { print(usage); exit(2) }
    let workspace = try CygnusWorkspace(directory: workspaceDirectory())
    let id = try await workspace.register(path: URL(fileURLWithPath: arguments[1]))
    print("registered \(id.raw)")

case "repos":
    let workspace = try CygnusWorkspace(directory: workspaceDirectory())
    for repo in try await workspace.repositories() {
        print("\(repo.id.raw)\t\(repo.displayName)\t\(repo.rootPath ?? "-")")
    }

case "index":
    let workspace = try CygnusWorkspace(directory: workspaceDirectory())
    let interactive = isatty(fileno(stdout)) == 1
    for repo in try await workspace.repositories() {
        let started = Date()
        let result = try await workspace.index(repo.id) { progress in
            if interactive && progress.total > 1 {
                print("\r\(progress.phase) \(progress.completed)/\(progress.total)", terminator: "")
            }
        }
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(started))
        print("\r\(repo.displayName): revision \(result.revision.raw), " +
              "\(result.filesAnalyzed) files (\(result.filesChanged) changed), " +
              "\(result.entityCount) entities, \(result.relationshipCount) edges asserted [\(elapsed)]")
    }

case "query":
    let workspace = try CygnusWorkspace(directory: workspaceDirectory())
    let store = await workspace.store
    switch arguments.dropFirst().first {
    case "contains":
        for tree in try Projections.containsTrees(store: store) {
            printTree(tree, indent: 0)
        }
    case "deps":
        let graph = try Projections.dependencyGraph(store: store)
        let byID = Dictionary(uniqueKeysWithValues: graph.entities.map { ($0.entity.id, $0) })
        for edge in graph.relationships {
            let from = byID[edge.source]?.version.name ?? "?"
            let to = byID[edge.target]?.version.name ?? "?"
            print("\(from) → \(to)")
        }
    default:
        print(usage); exit(2)
    }

case "revisions":
    let workspace = try CygnusWorkspace(directory: workspaceDirectory())
    for revision in try await workspace.store.revisions() {
        print("r\(revision.id.raw)\t\(revision.createdAt)\t\(revision.note ?? "")")
    }

case "bench":
    try StoreBenchmark.run()

default:
    print(usage)
}

func printTree(_ node: TreeProjection, indent: Int) {
    let kind = node.entity.entity.kind.rawValue.split(separator: ":").last.map(String.init) ?? ""
    print(String(repeating: "  ", count: indent) + "\(node.entity.version.name)  [\(kind)]")
    for child in node.children {
        printTree(child, indent: indent + 1)
    }
}

import Foundation
import CygnusGraph
import CygnusEngine
import CygnusStore
import CygnusQuery
import CygnusRetrieval
import CygnusProviders

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
  search <text> [n]  BM25 search over indexed source (default 10 hits)
  def <symbol>       where a symbol is defined
  refs <symbol>      what refers to it (compiler-resolved when built)
  callers <symbol>   what calls it — calls only, not every mention
  radius <symbol>    blast radius, ranked by centrality
  span <path> <a> <b>  read lines a..b from the snapshot, not the tree
  revisions          list graph revisions
  diff <r1> <r2>     what changed between two revisions
  verify             full rebuild vs incremental graph, per repository
  watch              continuous incremental analysis (FSEvents)
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

case "search":
    guard arguments.count >= 2 else { print(usage); exit(2) }
    let limit = arguments.count >= 3 ? Int(arguments[2]) ?? 10 : 10
    let searchDirectory = workspaceDirectory()
    let searchWorkspace = try CygnusWorkspace(directory: searchDirectory)
    let searchCAS = try ContentStore(root: searchDirectory.appendingPathComponent("cas"))
    let hits = try await searchWorkspace.withStore { store in
        try LexicalSearch(store: store, contentStore: searchCAS)
            .search(arguments[1], limit: limit)
    }
    if hits.isEmpty { print("no matches") }
    for hit in hits {
        // The shape the MCP surface will render: citation first, so it
        // can be pasted straight into a read, then how it was found.
        print("\(hit.citation)  [\(hit.layer.rawValue)/\(hit.resolution.rawValue)]")
        for line in (hit.snippet ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
            print("    \(line)")
        }
    }

case "def":
    guard arguments.count >= 2 else { print(usage); exit(2) }
    let defWorkspace = try CygnusWorkspace(directory: workspaceDirectory())
    let defs = try await defWorkspace.withStore { store in
        try Lookups.definitions(store: store, named: arguments[1])
    }
    if defs.isEmpty { print("no definitions") }
    for entity in defs {
        let anchor = entity.version.anchors.first
        let line = anchor?.range?.startLine ?? 0
        print("\(anchor?.path ?? "?"):\(line)  \(entity.version.name) "
            + "[\(entity.entity.kind.rawValue)]  observed/syntactic")
    }

case "refs", "callers":
    guard arguments.count >= 2 else { print(usage); exit(2) }
    let wantCalls = arguments[0] == "callers"
    let refWorkspace = try CygnusWorkspace(directory: workspaceDirectory())
    let answer = try await refWorkspace.withStore { store -> Lookups.ReferenceAnswer in
        // Accept a bare name as well as a stable key.
        let key: StableKey
        if arguments[1].contains(":") {
            key = StableKey(arguments[1])
        } else {
            guard let found = try Lookups.definitions(
                store: store, named: arguments[1], limit: 1).first else {
                return Lookups.ReferenceAnswer(references: [], evidence: .unavailable)
            }
            key = found.entity.stableKey
        }
        return wantCalls
            ? try Lookups.callers(store: store, of: key)
            : try Lookups.references(store: store, to: key)
    }
    if answer.evidence == .unavailable {
        // The distinction that matters: no answer is not the same as
        // an answer of none.
        print("unknown — this repository has no compiler-resolved symbol edges "
            + "(build it, then re-index)")
    } else if answer.references.isEmpty {
        print("none")
    }
    for reference in answer.references {
        let anchor = reference.source.version.anchors.first
        let counts = wantCalls
            ? "\(reference.callCount) call(s)"
            : "\(reference.referenceCount) reference(s), \(reference.callCount) call(s)"
        print("\(anchor?.path ?? "?"):\(anchor?.range?.startLine ?? 0)  "
            + "\(reference.source.version.name)  derived/compiler  \(counts)")
    }

case "radius":
    guard arguments.count >= 2 else { print(usage); exit(2) }
    let depth = arguments.count >= 3 ? Int(arguments[2]) ?? 2 : 2
    let radiusWorkspace = try CygnusWorkspace(directory: workspaceDirectory())
    let reached = try await radiusWorkspace.withStore { store -> [ResolvedEntity] in
        guard let found = try Lookups.definitions(
            store: store, named: arguments[1], limit: 1).first else { return [] }
        return try Lookups.blastRadius(store: store, of: found.entity.stableKey, depth: depth)
    }
    if reached.isEmpty { print("nothing reached") }
    for entity in reached.prefix(20) {
        print("\(entity.version.name)  [\(entity.entity.kind.rawValue)]  derived")
    }

case "span":
    guard arguments.count >= 4, let from = Int(arguments[2]), let to = Int(arguments[3])
    else { print(usage); exit(2) }
    let spanDirectory = workspaceDirectory()
    let spanWorkspace = try CygnusWorkspace(directory: spanDirectory)
    let spanCAS = try ContentStore(root: spanDirectory.appendingPathComponent("cas"))
    let span = try await spanWorkspace.withStore { store in
        try SpanReader(store: store, contentStore: spanCAS)
            .read(path: arguments[1], startLine: from, endLine: to)
    }
    var header = "\(span.repositoryName)/\(span.path):\(span.startLine)-\(span.endLine)"
    if span.stale { header += "  [stale: working tree has drifted from this snapshot]" }
    if let truncated = span.truncatedTo { header += "  [truncated at line \(truncated)]" }
    print(header)
    print(span.text)

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

case "diff":
    guard arguments.count >= 3, let from = Int64(arguments[1]), let to = Int64(arguments[2])
    else { print(usage); exit(2) }
    let workspace = try CygnusWorkspace(directory: workspaceDirectory())
    let delta = try await workspace.store.diff(from: RevisionID(from), to: RevisionID(to))
    print("r\(from) → r\(to): +\(delta.assertedEntityVersions.count) entities, " +
          "-\(delta.retractedEntityVersions.count) entities, " +
          "+\(delta.assertedRelationships.count) edges, " +
          "-\(delta.retractedRelationships.count) edges")
    for entity in delta.assertedEntityVersions.prefix(30) {
        print("  + \(entity.version.name)  (\(entity.entity.stableKey.raw))")
    }
    for entity in delta.retractedEntityVersions.prefix(30) {
        print("  - \(entity.version.name)  (\(entity.entity.stableKey.raw))")
    }

case "verify":
    let workspace = try CygnusWorkspace(directory: workspaceDirectory())
    var failed = false
    for repo in try await workspace.repositories() {
        let report = try await workspace.verify(repo.id)
        if report.isClean {
            print("\(repo.displayName): clean")
        } else {
            failed = true
            print("\(repo.displayName): \(report.staleFacts.count) stale, " +
                  "\(report.missingFacts.count) missing")
            for fact in report.staleFacts.prefix(20) { print("  stale: \(fact)") }
            for fact in report.missingFacts.prefix(20) { print("  missing: \(fact)") }
        }
    }
    exit(failed ? 1 : 0)

case "watch":
    let workspace = try CygnusWorkspace(directory: workspaceDirectory())
    let repos = try await workspace.repositories()
    let roots = repos.compactMap { $0.rootPath.map(URL.init(fileURLWithPath:)) }
    guard !roots.isEmpty else { print("no repositories registered"); exit(2) }
    print("watching \(roots.map(\.lastPathComponent).joined(separator: ", ")) — ^C to stop")

    let changes = AsyncStream<Void> { continuation in
        let watcher = FSWatcher(roots: roots) { continuation.yield() }
        continuation.onTermination = { _ in watcher.stop() }
    }
    // Index once on start so the baseline is current, then on change.
    for repo in repos {
        let result = try await workspace.index(repo.id)
        print("\(repo.displayName): revision \(result.revision.raw) (\(result.filesChanged) changed)")
    }
    for await _ in changes {
        for repo in repos {
            let result = try await workspace.index(repo.id)
            if result.filesChanged > 0 {
                print("\(repo.displayName): revision \(result.revision.raw) " +
                      "(\(result.filesChanged) changed)")
            }
        }
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

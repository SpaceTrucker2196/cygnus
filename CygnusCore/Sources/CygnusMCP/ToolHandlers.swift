import Foundation
import CygnusGraph
import CygnusStore
import CygnusQuery
import CygnusRetrieval
import CygnusEmbed
import CygnusProviders
import CygnusEngine

// Where the tools meet the engine.
//
// Every response obeys the same two rules, and they are the reason to
// use these tools rather than grep: each line carries a citation you
// can act on, and each line says how it was resolved — so an agent can
// always tell a compiler-resolved fact from a text match. Invariant 9
// enforced at the boundary where it actually matters.

public struct ToolHandlers: Sendable {
    private let workspace: CygnusWorkspace
    private let contentStore: ContentStore

    public init(workspace: CygnusWorkspace, contentStore: ContentStore) {
        self.workspace = workspace
        self.contentStore = contentStore
    }

    public func call(_ name: String, arguments: [String: JSONValue]) async throws -> String {
        guard let tool = ToolCatalog.tool(named: name) else {
            throw JSONRPCError.methodNotFound(name)
        }
        let maxTokens = ToolCatalog.budget(
            for: tool, requested: arguments["max_tokens"]?.intValue)
        let repo = try await resolveRepository(arguments["repo"]?.stringValue)

        switch name {
        case "cygnus_status":      return try await status()
        case "cygnus_prior_decisions": return try await decisions(arguments, repo, maxTokens)
        case "cygnus_factory_audit": return try await factoryAudit(repo, maxTokens)
        case "cygnus_repo_map":    return try await repoMap(arguments, repo, maxTokens)
        case "cygnus_search":      return try await search(arguments, repo, maxTokens)
        case "cygnus_find_definition": return try await definitions(arguments, repo, maxTokens)
        case "cygnus_find_references": return try await references(arguments, repo, maxTokens, callsOnly: false)
        case "cygnus_callers_of":  return try await references(arguments, repo, maxTokens, callsOnly: true)
        case "cygnus_blast_radius": return try await blastRadius(arguments, repo, maxTokens)
        case "cygnus_list_symbols": return try await listSymbols(arguments, repo, maxTokens)
        case "cygnus_read_span":   return try await readSpan(arguments, repo, maxTokens)
        default: throw JSONRPCError.methodNotFound(name)
        }
    }

    // MARK: - Tools

    /// Not garnish. Without this an agent silently reasons over a
    /// degraded corpus — unbuilt repositories, a stale index — with no
    /// way to discover that it is doing so.
    private func status() async throws -> String {
        let repositories = try await workspace.repositories()
        guard !repositories.isEmpty else {
            return "No repositories registered. Register one with `cygnus register <path>`."
        }
        var lines: [String] = []
        for repo in repositories {
            let summary = try await workspace.withStore { store -> String in
                let files = try store.entities(kind: .file, at: .current)
                    .filter { $0.entity.repository == repo.id }
                guard !files.isEmpty else { return "not indexed" }
                let references = try store.hasCompilerReferences(repository: repo.id)
                    ? "compiler" : "syntactic only (repository not built)"
                let entities = try Lookups.definitionKinds.reduce(0) { total, kind in
                    total + (try store.entities(kind: kind, at: .current)
                        .filter { $0.entity.repository == repo.id }.count)
                }
                return "\(files.count) files, \(entities) declarations, references: \(references)"
            }
            lines.append("\(repo.displayName): \(summary)")
        }
        lines.append("")
        // Read the real availability rather than asserting a constant —
        // an agent cannot reason about a degraded corpus it cannot see.
        lines.append("semantic search: "
            + EmbedderLocator.availability(workspace: await workspace.directory))
        return lines.joined(separator: "\n")
    }

    /// Factory readiness. Leads with what is missing or unfinished,
    /// because that is the actionable part; the parts already done need
    /// only be counted.
    private func factoryAudit(_ repo: RepositoryID?, _ maxTokens: Int) async throws -> String {
        let store = contentStore
        let reports = try await workspace.withStore { graph in
            try FactoryAudit(store: graph, contentStore: store).audit(repository: repo)
        }
        guard !reports.isEmpty else { return "No repositories registered." }

        var budget = TokenBudget(maxTokens: maxTokens)
        for report in reports {
            var block = "\(report.repositoryName): "
                + (report.isOperational ? "factory operational" : "NOT operational")
                + "  (\(report.real.count) real, \(report.stubs.count) unfilled, "
                + "\(report.missing.count) missing)"
            for component in report.stubs {
                block += "\n    unfilled  \(component.path)"
                    + (component.marker.map { "  — still contains \"\($0)\"" } ?? "")
            }
            for component in report.missing {
                block += "\n    missing   \(component.path)  — \(component.purpose)"
            }
            guard budget.admitCounted(block) else { break }
        }
        return budget.finish(total: reports.count)
    }

    /// The record of what was already settled. Deliberately verbose
    /// about refusals: an adopted decision usually left code behind
    /// that an agent will trip over anyway, but a refusal left nothing
    /// at all, and that is the one worth spending tokens on.
    private func decisions(_ arguments: [String: JSONValue],
                           _ repo: RepositoryID?, _ maxTokens: Int) async throws -> String {
        let topic = arguments["topic"]?.stringValue
        let store = contentStore
        let records = try await workspace.withStore { graph -> [DecisionRecord] in
            let reader = DecisionReader(store: graph, contentStore: store)
            return try topic.map { try reader.matching($0, repository: repo) }
                ?? reader.all(repository: repo)
        }
        guard !records.isEmpty else {
            return topic.map {
                "No recorded decision mentions \($0). Note this means *no record*, "
                + "not that the question is open — a repository without DECISIONS.md "
                + "has simply never written its decisions down."
            } ?? "No decisions recorded. Repositories record them in DECISIONS.md."
        }

        var budget = TokenBudget(maxTokens: maxTokens)
        let refused = records.filter { $0.status == .refused }.count
        budget.admitAlways("\(records.count) recorded decision(s)"
            + (refused > 0 ? ", \(refused) of them refusals" : ""))
        for record in records {
            var block = "\(record.repositoryName)/DECISIONS.md  \(record.id) "
                + "[\(record.status.rawValue)] \(record.date)  \(record.summary)"
            if !record.evidence.isEmpty, record.evidence.lowercased() != "none" {
                block += "\n    evidence: \(record.evidence)"
            }
            if let detail = record.detail, record.status == .refused {
                block += "\n" + detail.split(separator: "\n")
                    .prefix(6).map { "    \($0)" }.joined(separator: "\n")
            }
            guard budget.admitCounted(block) else { break }
        }
        return budget.finish(total: records.count)
    }

    private func repoMap(_ arguments: [String: JSONValue],
                         _ repo: RepositoryID?, _ maxTokens: Int) async throws -> String {
        let focus = arguments["focus"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let repositories = try await workspace.repositories()
        let targets = repo.map { id in repositories.filter { $0.id == id } } ?? repositories
        guard !targets.isEmpty else { return "No repositories registered." }

        var rendered: [String] = []
        // Split the budget when mapping several repositories, or the
        // first one eats all of it and the rest silently vanish.
        let each = max(TokenBudget.floorTokens, maxTokens / targets.count)
        for target in targets {
            rendered.append(try await workspace.withStore { store in
                try RepoMap(store: store).render(
                    repository: target.id, options: .init(maxTokens: each, focus: focus))
            })
        }
        return rendered.joined(separator: "\n\n")
    }

    private func search(_ arguments: [String: JSONValue],
                        _ repo: RepositoryID?, _ maxTokens: Int) async throws -> String {
        guard let query = arguments["query"]?.stringValue, !query.isEmpty else {
            throw JSONRPCError.invalidParams("query is required")
        }
        let limit = min(arguments["limit"]?.intValue ?? 10, 50)
        let prefix = arguments["path_prefix"]?.stringValue
        let focus = arguments["focus"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let requested = arguments["mode"]?.stringValue
            .flatMap(HybridSearch.Mode.init(rawValue:)) ?? .hybrid

        // Asking for semantic when none exists is an error rather than
        // a silent downgrade: the caller chose that mode for a reason.
        let embedder = HybridSearch.embedder(workspace: await workspace.directory)
        if requested == .semantic, embedder == nil {
            return "Semantic search is unavailable — no embedding model is installed. "
                + "Run tools/convert-embedder.py or set \(EmbedderLocator.environmentKey), "
                + "or search with mode \"lexical\"."
        }

        let store = contentStore
        let outcome = try await workspace.withStore { graph in
            HybridSearch(store: graph, contentStore: store, embedder: embedder)
        }.search(query, mode: requested, repository: repo,
                 pathPrefix: prefix, focus: focus, limit: limit)
        let results = outcome.results
        guard !results.isEmpty else { return "No matches for \(query)." }

        var budget = TokenBudget(maxTokens: maxTokens)
        var header = "\(results.count) hit(s) for \(query) — \(outcome.modeUsed.rawValue)"
        // Never substitute a weaker answer silently.
        if let degraded = outcome.degraded { header += "\n(\(degraded))" }
        budget.admitAlways(header)
        for result in results {
            let citation = "\(result.citation)  [\(result.layer.rawValue)/\(result.resolution.rawValue)]"
            let body = result.snippet.map { snippet in
                snippet.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "    \($0)" }.joined(separator: "\n")
            }
            guard budget.admitResult(citation: citation, body: body) else { break }
        }
        return budget.finish(total: results.count)
    }

    private func definitions(_ arguments: [String: JSONValue],
                             _ repo: RepositoryID?, _ maxTokens: Int) async throws -> String {
        guard let symbol = arguments["symbol"]?.stringValue else {
            throw JSONRPCError.invalidParams("symbol is required")
        }
        let limit = min(arguments["limit"]?.intValue ?? 10, 50)
        let found = try await workspace.withStore { store in
            try Lookups.definitions(store: store, named: symbol,
                                    repository: repo, limit: limit)
        }
        guard !found.isEmpty else { return "No definition of \(symbol) in the indexed graph." }

        var budget = TokenBudget(maxTokens: maxTokens)
        budget.admitAlways("\(found.count) definition(s) of \(symbol)")
        for entity in found {
            guard budget.admitCounted(Rendering.declaration(entity)) else { break }
        }
        return budget.finish(total: found.count)
    }

    private func references(_ arguments: [String: JSONValue], _ repo: RepositoryID?,
                            _ maxTokens: Int, callsOnly: Bool) async throws -> String {
        guard let symbol = arguments["symbol"]?.stringValue else {
            throw JSONRPCError.invalidParams("symbol is required")
        }
        let answer = try await workspace.withStore { store -> Lookups.ReferenceAnswer in
            let key: StableKey
            if symbol.contains(":") {
                key = StableKey(symbol)
            } else {
                guard let match = try Lookups.definitions(
                    store: store, named: symbol, repository: repo, limit: 1).first else {
                    return Lookups.ReferenceAnswer(references: [], evidence: .unavailable)
                }
                key = match.entity.stableKey
            }
            return callsOnly
                ? try Lookups.callers(store: store, of: key)
                : try Lookups.references(store: store, to: key)
        }

        // The distinction the whole tool exists to preserve.
        guard answer.evidence == .compiler else {
            return """
                Unknown — no compiler-resolved symbol edges exist for this repository, \
                so nothing can be said about what \(callsOnly ? "calls" : "references") \
                \(symbol). This is not the same as "nothing does". Build the repository \
                and re-index to get an answer.
                """
        }
        guard !answer.references.isEmpty else {
            return "Nothing \(callsOnly ? "calls" : "references") \(symbol). "
                + "(Compiler-resolved, so this is a real answer, not missing data.)"
        }

        var budget = TokenBudget(maxTokens: maxTokens)
        budget.admitAlways(
            "\(answer.references.count) \(callsOnly ? "caller" : "reference")(s) of \(symbol)")
        for reference in answer.references {
            guard budget.admitCounted(
                Rendering.reference(reference, callsOnly: callsOnly)) else { break }
        }
        return budget.finish(total: answer.references.count)
    }

    private func blastRadius(_ arguments: [String: JSONValue],
                             _ repo: RepositoryID?, _ maxTokens: Int) async throws -> String {
        guard let symbol = arguments["symbol"]?.stringValue else {
            throw JSONRPCError.invalidParams("symbol is required")
        }
        let depth = min(arguments["depth"]?.intValue ?? 2, 4)
        let reached = try await workspace.withStore { store -> [ResolvedEntity] in
            guard let match = try Lookups.definitions(
                store: store, named: symbol, repository: repo, limit: 1).first else { return [] }
            return try Lookups.blastRadius(store: store, of: match.entity.stableKey, depth: depth)
        }
        guard !reached.isEmpty else { return "Nothing reachable from \(symbol)." }

        var budget = TokenBudget(maxTokens: maxTokens)
        budget.admitAlways("\(reached.count) entities within depth \(depth) of \(symbol), "
            + "most central first")
        for entity in reached {
            guard budget.admitCounted(Rendering.declaration(entity)) else { break }
        }
        return budget.finish(total: reached.count)
    }

    private func listSymbols(_ arguments: [String: JSONValue],
                             _ repo: RepositoryID?, _ maxTokens: Int) async throws -> String {
        guard let path = arguments["path"]?.stringValue else {
            throw JSONRPCError.invalidParams("path is required")
        }
        let symbols = try await workspace.withStore { store in
            try Lookups.symbols(store: store, in: path)
        }
        guard !symbols.isEmpty else {
            return "No declarations recorded for \(path). "
                + "Either the file has none, or its language has no extractor yet."
        }
        var budget = TokenBudget(maxTokens: maxTokens)
        budget.admitAlways("\(symbols.count) declaration(s) in \(path)")
        for symbol in symbols {
            guard budget.admitCounted(Rendering.declaration(symbol)) else { break }
        }
        return budget.finish(total: symbols.count)
    }

    private func readSpan(_ arguments: [String: JSONValue],
                          _ repo: RepositoryID?, _ maxTokens: Int) async throws -> String {
        guard let path = arguments["path"]?.stringValue else {
            throw JSONRPCError.invalidParams("path is required")
        }
        guard let from = arguments["start_line"]?.intValue,
              let to = arguments["end_line"]?.intValue else {
            throw JSONRPCError.invalidParams("start_line and end_line are required")
        }
        let store = contentStore
        let span = try await workspace.withStore { graph in
            try SpanReader(store: graph, contentStore: store)
                .read(path: path, startLine: from, endLine: to, repository: repo)
        }
        var header = "\(span.repositoryName)/\(span.path):\(span.startLine)-\(span.endLine)"
        if span.stale {
            header += "  [stale — the working tree has drifted from this snapshot; "
                + "the text below is what the line numbers refer to]"
        }
        if let truncated = span.truncatedTo { header += "  [capped at line \(truncated)]" }

        var budget = TokenBudget(maxTokens: maxTokens)
        budget.admitAlways(header)
        _ = budget.admit(span.text)
        return budget.finish(total: 1)
    }

    // MARK: - Internals

    private func resolveRepository(_ name: String?) async throws -> RepositoryID? {
        guard let name else { return nil }
        let repositories = try await workspace.repositories()
        guard let match = repositories.first(where: {
            $0.displayName == name || $0.id.raw == name
        }) else {
            throw JSONRPCError.invalidParams("unknown repository: \(name)")
        }
        return match.id
    }
}

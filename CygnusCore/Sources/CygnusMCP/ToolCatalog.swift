import Foundation

// The tools, their schemas, and their ceilings.
//
// The `description` fields are product surface, not documentation. A
// coding agent already has grep, glob and file-read; if these
// descriptions do not say precisely when cygnus beats them —
// cross-repository, compiler-resolved, centrality-ranked,
// snapshot-consistent — the tools simply never get called and the
// whole build is wasted. They are written as routing instructions to a
// capable peer, and they deserve review as carefully as the code.

public struct ToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let schema: JSONValue
    /// Server-side ceiling. A client cannot raise it: budgets exist to
    /// protect the context window, and a tool that honours "give me
    /// 50k tokens" is not a budget.
    public let maxTokens: Int
}

public enum ToolCatalog {
    static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static func integer(_ description: String, default value: Int, max: Int? = nil) -> JSONValue {
        var fields: [String: JSONValue] = [
            "type": .string("integer"),
            "description": .string(description),
            "default": .number(Double(value)),
        ]
        if let max { fields["maximum"] = .number(Double(max)) }
        return .object(fields)
    }

    static func schema(properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }

    private static let repoArgument = string(
        "Repository display name. Omit to search every indexed repository.")

    public static let tools: [ToolDefinition] = [
        ToolDefinition(
            name: "cygnus_status",
            description: """
                What cygnus currently knows, per repository: how recently it was \
                indexed, how many files and entities, whether compiler-resolved \
                references are available, and whether semantic search is ready. \
                Call this first when a later answer looks thin — it distinguishes \
                "there is nothing there" from "this repository was never built, so \
                nothing can be known".
                """,
            schema: schema(properties: [:]),
            maxTokens: 800),

        ToolDefinition(
            name: "cygnus_factory_audit",
            description: """
                Whether a repository is actually running a dark factory, and what \
                is missing or unfinished. Distinguishes a document that exists from \
                one that was filled in — a repo that installed the template and \
                never adapted it has every file and no factory, which counting \
                files would score as complete. Use when setting a prototype up as a \
                factory, or before trusting that a repo's conventions are written \
                down anywhere.
                """,
            schema: schema(properties: [
                "repo": repoArgument,
                "max_tokens": integer("Response ceiling.", default: 2000, max: 4000),
            ]),
            maxTokens: 4000),

        ToolDefinition(
            name: "cygnus_prior_decisions",
            description: """
                What this factory has already decided — and, more importantly, what \
                it has already tried and rejected. Call this BEFORE proposing an \
                architectural change, a new dependency, or a tool the repository \
                might have evaluated before. A refusal leaves no code behind, so \
                nothing in the tree will remind you it happened; this is the only \
                place that record exists. Pass a topic to filter, or omit it to see \
                everything.
                """,
            schema: schema(properties: [
                "topic": string("Words to match against decisions; omit for all."),
                "repo": repoArgument,
                "max_tokens": integer("Response ceiling.", default: 2000, max: 4000),
            ]),
            maxTokens: 4000),

        ToolDefinition(
            name: "cygnus_repo_map",
            description: """
                A ranked skeleton of a repository: directories and files ordered by \
                centrality in the dependency graph, each with its main types and \
                functions. Use this to orient in an unfamiliar repository before \
                reading anything — it answers "where does this system's weight sit" \
                in ~3k tokens, which listing files cannot. Pass `focus` symbols to \
                re-rank around the task at hand.
                """,
            schema: schema(properties: [
                "repo": repoArgument,
                "focus": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string(
                        "Symbols the task centres on; re-ranks the map around them."),
                ]),
                "max_tokens": integer("Response ceiling.", default: 3000, max: 5000),
            ]),
            maxTokens: 5000),

        ToolDefinition(
            name: "cygnus_search",
            description: """
                Full-text search across every indexed repository, ranked by BM25, \
                returning exact file:line citations with context. Prefer this over \
                grep when the target may live in another repository, when you want \
                results ranked rather than in file order, or when you are searching \
                for words that appear inside camelCase identifiers — "task group" \
                finds withThrowingTaskGroup here, and does not under grep. Searches \
                the indexed snapshot, so results are consistent with the line \
                numbers other cygnus tools return.
                """,
            schema: schema(properties: [
                "query": string("Text to search for."),
                "repo": repoArgument,
                "path_prefix": string("Restrict to paths beginning with this, e.g. Sources/."),
                "limit": integer("Maximum hits.", default: 10, max: 50),
                "max_tokens": integer("Response ceiling.", default: 4000, max: 8000),
            ], required: ["query"]),
            maxTokens: 8000),

        ToolDefinition(
            name: "cygnus_find_definition",
            description: """
                Where a symbol is defined, with its kind and exact line. Resolved \
                from parsed declarations rather than text, so it does not return \
                every mention of the name, and it works across all indexed \
                repositories at once.
                """,
            schema: schema(properties: [
                "symbol": string("Symbol name."),
                "repo": repoArgument,
                "limit": integer("Maximum definitions.", default: 10, max: 50),
                "max_tokens": integer("Response ceiling.", default: 1500, max: 4000),
            ], required: ["symbol"]),
            maxTokens: 4000),

        ToolDefinition(
            name: "cygnus_find_references",
            description: """
                What refers to a symbol, resolved by the compiler's index rather \
                than guessed from text — so it will not match a comment or an \
                unrelated identically-named symbol. Reports honestly when the \
                repository has not been built, in which case nothing can be known \
                and the answer says so rather than returning an empty list.
                """,
            schema: schema(properties: [
                "symbol": string("Symbol name, or a full stable key."),
                "repo": repoArgument,
                "max_tokens": integer("Response ceiling.", default: 2000, max: 4000),
            ], required: ["symbol"]),
            maxTokens: 4000),

        ToolDefinition(
            name: "cygnus_callers_of",
            description: """
                What actually calls a symbol — calls only, not every mention of it. \
                The distinction is large: in this codebase 93% of symbol references \
                are not calls, so a caller list built from references would be \
                wrong far more often than right. Use before changing a function's \
                behaviour or signature.
                """,
            schema: schema(properties: [
                "symbol": string("Symbol name, or a full stable key."),
                "repo": repoArgument,
                "max_tokens": integer("Response ceiling.", default: 2000, max: 4000),
            ], required: ["symbol"]),
            maxTokens: 4000),

        ToolDefinition(
            name: "cygnus_blast_radius",
            description: """
                What a change to this symbol could reach, walking reference and \
                import edges outward and ordering by centrality so the most \
                important consequences come first. Use to size a change before \
                making it.
                """,
            schema: schema(properties: [
                "symbol": string("Symbol name."),
                "repo": repoArgument,
                "depth": integer("How far to walk.", default: 2, max: 4),
                "max_tokens": integer("Response ceiling.", default: 2000, max: 4000),
            ], required: ["symbol"]),
            maxTokens: 4000),

        ToolDefinition(
            name: "cygnus_list_symbols",
            description: """
                Every declaration in a file, in source order, with kinds and line \
                numbers — the shape of a file without reading it. Much cheaper than \
                reading the file when you only need to know what is in it.
                """,
            schema: schema(properties: [
                "path": string("Repository-relative path."),
                "repo": repoArgument,
                "max_tokens": integer("Response ceiling.", default: 2000, max: 4000),
            ], required: ["path"]),
            maxTokens: 4000),

        ToolDefinition(
            name: "cygnus_read_span",
            description: """
                Read a line range from the indexed snapshot rather than from disk. \
                Use this when following a citation from another cygnus tool: those \
                line numbers refer to the snapshot, and reading the working tree \
                instead can silently return different text. Says so explicitly when \
                the file on disk has drifted from the snapshot. Capped at 400 lines \
                — request a range, never a whole file.
                """,
            schema: schema(properties: [
                "path": string("Repository-relative path."),
                "start_line": integer("First line, 1-based.", default: 1),
                "end_line": integer("Last line, inclusive.", default: 40),
                "repo": repoArgument,
                "max_tokens": integer("Response ceiling.", default: 6000, max: 8000),
            ], required: ["path", "start_line", "end_line"]),
            maxTokens: 8000),
    ]

    public static func tool(named name: String) -> ToolDefinition? {
        tools.first { $0.name == name }
    }

    /// Clamp a client-supplied budget to the tool's ceiling.
    public static func budget(for tool: ToolDefinition, requested: Int?) -> Int {
        min(requested ?? tool.maxTokens, tool.maxTokens)
    }

    public static var listing: JSONValue {
        .object(["tools": .array(tools.map { tool in
            .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "inputSchema": tool.schema,
            ])
        })])
    }
}

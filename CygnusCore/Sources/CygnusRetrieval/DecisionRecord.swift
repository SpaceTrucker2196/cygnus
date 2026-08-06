import Foundation
import CygnusGraph
import CygnusStore
import CygnusProviders

// The factory's memory of what it already settled.
//
// A repository records its code in code, but it records its *rejected*
// options nowhere — a refusal leaves no artifact behind, so nothing in
// the tree reminds anyone it happened. That is why the same idea gets
// rebuilt every few months by whoever arrives next, and why "we
// measured this and it does not work" is the most expensive knowledge
// a factory owns and the easiest to lose.
//
// DECISIONS.md is where the template puts them. This reads it out of
// the indexed snapshot — not the working tree — so an answer is
// consistent with everything else cygnus says.

public struct DecisionRecord: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable {
        case adopted, refused, provisional, superseded, unknown

        init(parsing raw: String) {
            self = Status(rawValue: raw.lowercased().trimmingCharacters(in: .whitespaces))
                ?? .unknown
        }
    }

    public let id: String
    public let date: String
    public let summary: String
    public let status: Status
    public let evidence: String
    public let supersedes: String?
    public let repositoryName: String

    /// The `## <id> — …` section body, when the file carries one.
    public var detail: String?
}

public struct DecisionReader: Sendable {
    private let store: SQLiteGraphStore
    private let contentStore: ContentStore

    public init(store: SQLiteGraphStore, contentStore: ContentStore) {
        self.store = store
        self.contentStore = contentStore
    }

    public static let path = "DECISIONS.md"

    /// Every recorded decision across the workspace, newest first.
    public func all(repository: RepositoryID? = nil) throws -> [DecisionRecord] {
        var records: [DecisionRecord] = []
        for repo in try store.repositories()
        where repository == nil || repo.id == repository {
            guard let blob = try store.currentBlob(forPath: Self.path, repository: repo.id),
                  blob != RetrievalIndexer.notIngested,
                  let text = String(data: try contentStore.read(blob), encoding: .utf8)
            else { continue }
            records += Self.parse(text, repositoryName: repo.displayName)
        }
        return records.sorted { lhs, rhs in
            lhs.date == rhs.date ? lhs.id < rhs.id : lhs.date > rhs.date
        }
    }

    /// Decisions whose summary, evidence or detail mentions any of the
    /// query's words. Deliberately generous: the cost of surfacing an
    /// irrelevant past decision is a line of output, and the cost of
    /// missing a relevant one is rebuilding something already refused.
    public func matching(_ query: String,
                         repository: RepositoryID? = nil) throws -> [DecisionRecord] {
        let terms = IdentifierSplitter.queryTerms(query)
            .map { $0.lowercased() }
            .filter { $0.count > 2 }
        guard !terms.isEmpty else { return try all(repository: repository) }

        return try all(repository: repository).filter { record in
            let haystack = [record.summary, record.evidence, record.detail ?? ""]
                .joined(separator: " ")
                .lowercased()
            return terms.contains { haystack.contains($0) }
        }
    }

    // MARK: - Parsing

    /// Reads the pipe-table index and attaches each row's `## <id> — …`
    /// section. Tolerant by design: a half-filled record is still worth
    /// surfacing, and refusing to parse one would hide exactly the
    /// entry someone forgot to finish.
    static func parse(_ text: String, repositoryName: String) -> [DecisionRecord] {
        let lines = text.components(separatedBy: "\n")
        var records: [DecisionRecord] = []
        var details: [String: String] = [:]

        // Sections first, so rows can claim them.
        var currentID: String?
        var buffer: [String] = []
        func flush() {
            if let id = currentID, !buffer.isEmpty {
                details[id] = buffer.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            buffer = []
        }
        for line in lines {
            if line.hasPrefix("## ") {
                flush()
                // "## D3 — title" → "D3"
                currentID = line.dropFirst(3)
                    .split(whereSeparator: { $0 == " " || $0 == "—" || $0 == "-" })
                    .first.map(String.init)
            } else if currentID != nil {
                buffer.append(line)
            }
        }
        flush()

        for line in lines where line.contains("|") {
            let cells = line
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 5 else { continue }
            let id = cells[0]
            // Skip the header and the |---| separator.
            guard !id.isEmpty, id.lowercased() != "id",
                  !id.allSatisfy({ $0 == "-" || $0 == ":" }) else { continue }
            // Skip the template's own example row.
            guard !cells[2].contains("example") else { continue }

            records.append(DecisionRecord(
                id: id,
                date: cells[1],
                summary: cells[2],
                status: DecisionRecord.Status(parsing: cells[3]),
                evidence: cells[4],
                supersedes: cells.count > 5 && cells[5] != "—" && !cells[5].isEmpty
                    ? cells[5] : nil,
                repositoryName: repositoryName,
                detail: details[id]))
        }
        return records
    }
}

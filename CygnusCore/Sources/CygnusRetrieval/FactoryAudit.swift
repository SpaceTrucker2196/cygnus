import Foundation
import CygnusGraph
import CygnusStore
import CygnusProviders

// Is this repository actually running a dark factory, and if not, what
// is missing?
//
// The question sounds like a filesystem walk and isn't. Cygnus has
// already indexed these repositories, so factory readiness is a
// projection over the snapshot — which means the answer is consistent
// with everything else cygnus says, and it covers every registered
// repository at once rather than whichever one someone is standing in.
//
// The distinction that carries the whole thing is **present vs real**.
// A repository that installed the template and never filled it in has
// every file and no factory: MISSION.md full of `[invariant]`,
// FACTORY.md still telling you to rewrite it. Counting files would
// score that as complete, which is worse than scoring it as absent,
// because it reads as documentation.

public struct FactoryAudit: Sendable {
    private let store: SQLiteGraphStore
    private let contentStore: ContentStore

    public init(store: SQLiteGraphStore, contentStore: ContentStore) {
        self.store = store
        self.contentStore = contentStore
    }

    public enum State: String, Sendable {
        /// Present and filled in for this repository.
        case real
        /// Present but still carrying template placeholders.
        case stub
        case missing
    }

    public struct Component: Sendable {
        public let path: String
        public let state: State
        /// Why it was judged a stub, when it was.
        public let marker: String?
        public let purpose: String
    }

    public struct Report: Sendable {
        public let repositoryName: String
        public let components: [Component]

        public var missing: [Component] { components.filter { $0.state == .missing } }
        public var stubs: [Component] { components.filter { $0.state == .stub } }
        public var real: [Component] { components.filter { $0.state == .real } }

        /// A factory is operational when the load-bearing documents are
        /// real. FIRST_RUN.md still being present means the opposite of
        /// what its presence suggests — the adaptation never finished.
        /// Operational means the three load-bearing documents are real
        /// — in whatever layout this repository uses — and the
        /// adaptation finished. Everything else is worth having and
        /// none of it is what makes an agent able to work here cold.
        public var isOperational: Bool {
            let realPaths = Set(real.map(\.path))
            func has(_ alternates: [String]) -> Bool {
                alternates.contains(where: realPaths.contains)
            }
            return has(["MISSION.md", "agents/MISSION.md"])
                && has(["AGENTS.md", "CLAUDE.md", "agents/AGENTS.md"])
                && has(["FACTORY.md", "agents/FACTORY.md"])
                && !components.contains { $0.path == "FIRST_RUN.md" }
        }
    }

    /// What a factory is made of, and why each part is there.
    ///
    /// Each component lists **every layout we accept**, because the
    /// canonical factory does not use the template's. sloth keeps its
    /// charter under `agents/` and its wiki under `docs/wiki/`; an
    /// audit that only knew the template's paths would report the
    /// repository the pattern is named after as not running it, which
    /// is worse than useless — it would teach an agent to "fix" a
    /// working factory into the template's shape.
    struct Expectation {
        let paths: [String]
        let purpose: String
        /// FIRST_RUN.md is the inversion: its *presence* is the
        /// finding. Absence means the adaptation finished, so it must
        /// never be reported as a gap.
        var presenceIsTheProblem = false
    }

    static let expected: [Expectation] = [
        Expectation(paths: ["MISSION.md", "agents/MISSION.md"],
                    purpose: "the charter and the sacred invariants"),
        Expectation(paths: ["AGENTS.md", "CLAUDE.md", "agents/AGENTS.md"],
                    purpose: "repo-local rules for any coding agent"),
        Expectation(paths: ["FACTORY.md", "agents/FACTORY.md"],
                    purpose: "the build runbook and the test oracle"),
        Expectation(paths: ["PROGRESS.md"],
                    purpose: "in-flight state a cold agent needs"),
        Expectation(paths: ["DECISIONS.md"],
                    purpose: "what was decided, and what was refused"),
        Expectation(paths: ["METRICS.md"],
                    purpose: "one row per shipped production order"),
        Expectation(paths: ["ROADMAP.md", "docs/milestones.md"],
                    purpose: "forward direction as sized milestones"),
        Expectation(paths: ["SECURITY.md"],
                    purpose: "threat model and the frozen outbound surface"),
        Expectation(paths: ["docs/dark-factory.md", "agents/dark-factory.md"],
                    purpose: "the pattern and the autonomy contract"),
        Expectation(paths: ["docs/converge.md", "agents/converge.md",
                            ".claude/commands/converge.md"],
                    purpose: "how one production order ships"),
        Expectation(paths: ["wiki/README.md", "docs/wiki/home.md"],
                    purpose: "the knowledge base research accumulates in"),
        Expectation(paths: [".github/workflows/pages.yml"],
                    purpose: "publishes the wiki as a site"),
        Expectation(paths: ["FIRST_RUN.md"],
                    purpose: "adaptation never finished — fill the stubs, then delete it",
                    presenceIsTheProblem: true),
    ]

    /// Text that only survives in a file nobody adapted. Each is a
    /// literal from the template rather than a heuristic, so a false
    /// "stub" verdict means someone really did leave it in.
    static let stubMarkers = [
        "{{REPO_NAME}}",
        "> FIRST RUN:",
        "[invariant]",
        "[non-goal]",
        "[first milestone]",
        "[One paragraph:",
        "(example — delete on first run)",
    ]

    public func audit(repository: RepositoryID? = nil) throws -> [Report] {
        try store.repositories()
            .filter { repository == nil || $0.id == repository }
            .map { repo in
                Report(repositoryName: repo.displayName,
                       components: Self.expected.compactMap { component(repo.id, $0) })
            }
    }

    /// Nil when there is nothing to report — which is the normal case
    /// for FIRST_RUN.md, whose absence is the success condition.
    private func component(_ repo: RepositoryID, _ expectation: Expectation) -> Component? {
        let found = expectation.paths.first { path in
            ((try? store.currentBlob(forPath: path, repository: repo)) ?? nil) != nil
        }
        guard let path = found else {
            return expectation.presenceIsTheProblem
                ? nil
                : Component(path: expectation.paths[0], state: .missing,
                            marker: nil, purpose: expectation.purpose)
        }
        if expectation.presenceIsTheProblem {
            return Component(path: path, state: .stub, marker: nil,
                             purpose: expectation.purpose)
        }
        return classify(repo, path, expectation.purpose)
    }

    private func classify(_ repo: RepositoryID, _ path: String, _ purpose: String) -> Component {
        guard let blob = (try? store.currentBlob(forPath: path, repository: repo)) ?? nil else {
            return Component(path: path, state: .missing, marker: nil, purpose: purpose)
        }
        guard blob != RetrievalIndexer.notIngested,
              let data = try? contentStore.read(blob),
              let text = String(data: data, encoding: .utf8) else {
            // Present but unreadable counts as present, not as filled
            // in — we cannot claim it says anything.
            return Component(path: path, state: .stub, marker: "unreadable", purpose: purpose)
        }
        if let marker = Self.stubMarkers.first(where: text.contains) {
            return Component(path: path, state: .stub, marker: marker, purpose: purpose)
        }
        return Component(path: path, state: .real, marker: nil, purpose: purpose)
    }
}

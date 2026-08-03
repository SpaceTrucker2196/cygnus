import Foundation
import CygnusGraph
import CygnusStore
import CygnusProviders
import CygnusObservation

// Who has worked on what, and what that implies about ownership.
//
// *Kill It With Fire*: "There are parts of the system with shared
// ownership, parts that no one is responsible for at all, parts where
// responsibilities are split in unintuitive ways. When looking for bad
// technology, debt, or security issues, the most productive places to
// mine are gaps between what two components of the same organization
// officially own" (p. 98).
//
// The layering is the point. Git says who committed — observed. Commit
// counts per file are arithmetic — derived. "This person owns it" is a
// judgement about concentration — inferred, and held to a higher bar
// than the counting beneath it.

extension CygnusWorkspace {
    /// Share of a file's commits one author must hold before we are
    /// willing to call them its owner. Below this the file is shared,
    /// which is a finding rather than a missing answer.
    static let ownershipThreshold = 0.6

    /// Provenance rows kept per edge. A file with a thousand commits
    /// does not need a thousand links to say who wrote it — the same
    /// cap reference enrichment uses.
    static let maxProvenancePerEdge = 200

    /// Read git authorship, record one observation per (commit, file)
    /// touch, then assert derived `core:authoredBy` edges with counts
    /// and inferred `core:ownedBy` edges where one author dominates.
    /// Returns the committed revision, or nil when there is no history
    /// or nothing changed.
    func enrichOwnership(repoID: RepositoryID, root: URL, snapshot: SnapshotID,
                         currentPaths: Set<String>,
                         displayName: String,
                         limit: Int = GitHistory.defaultCommitLimit,
                         progress: (@Sendable (IndexProgress) -> Void)? = nil)
        throws -> RevisionID? {
        let commits = GitHistory.commits(of: root, limit: limit)
        guard !commits.isEmpty else { return nil }
        progress?(IndexProgress(phase: "ownership", completed: 0, total: 1))

        // Only touches on files in the current snapshot are evidence
        // about it. History remembers deleted files; the graph is
        // about what is here now.
        struct Touch {
            let path: String
            let identity: String
            let name: String
            let email: String
            let sha: String
            let date: Date
        }
        var touches: [Touch] = []
        for commit in commits {
            let identity = GitHistory.identity(email: commit.authorEmail,
                                               name: commit.authorName)
            guard !identity.isEmpty else { continue }
            for path in commit.paths where currentPaths.contains(path) {
                touches.append(Touch(path: path, identity: identity,
                                     name: commit.authorName, email: commit.authorEmail,
                                     sha: commit.sha, date: commit.date))
            }
        }
        guard !touches.isEmpty else { return nil }

        let extractor = ExtractorIdentity(name: "git-authorship", version: "0.1.0")
        let observations = touches.map { touch in
            Observation(
                kind: .authorship,
                file: SourceAnchor(path: touch.path, blob: BlobHash(""), range: nil),
                payload: [
                    ObservationPayload.authorName: .string(touch.name),
                    ObservationPayload.authorEmail: .string(touch.email),
                    ObservationPayload.commitSHA: .string(touch.sha),
                    ObservationPayload.commitDate: .string(
                        ISO8601DateFormatter().string(from: touch.date)),
                ],
                extractor: extractor)
        }
        let observationIDs = try store.recordObservations(observations, snapshot: snapshot)

        // Aggregate per (file, author).
        struct Tally {
            var commits = 0
            var lastTouched: Date = .distantPast
            var name = ""
            var supportedBy: [ObservationID] = []
        }
        var byPair: [String: Tally] = [:]
        var pairKeys: [String: (path: String, identity: String)] = [:]
        var perFileTotal: [String: Int] = [:]
        for (index, touch) in touches.enumerated() {
            let key = "\(touch.path)\u{1}\(touch.identity)"
            var tally = byPair[key] ?? Tally()
            tally.commits += 1
            tally.name = touch.name
            tally.lastTouched = max(tally.lastTouched, touch.date)
            if tally.supportedBy.count < Self.maxProvenancePerEdge {
                tally.supportedBy.append(observationIDs[index])
            }
            byPair[key] = tally
            pairKeys[key] = (touch.path, touch.identity)
            perFileTotal[touch.path, default: 0] += 1
        }

        // When each person last committed anywhere in this repository.
        // A person who has stopped committing is how institutional
        // knowledge leaves, so the date belongs on the person, not on
        // any one file they touched.
        var lastCommitByPerson: [String: Date] = [:]
        for touch in touches {
            lastCommitByPerson[touch.identity] =
                max(lastCommitByPerson[touch.identity] ?? .distantPast, touch.date)
        }

        var changes = RevisionChanges()
        var assertedPeople = Set<String>()
        var dominant: [String: (identity: String, share: Double, supportedBy: [ObservationID])] = [:]

        for (key, tally) in byPair.sorted(by: { $0.key < $1.key }) {
            guard let (path, identity) = pairKeys[key] else { continue }
            let personKey = StableKeys.person(identity)
            if assertedPeople.insert(identity).inserted {
                var properties: PropertyBag = [
                    ObservationPayload.authorEmail: .string(identity),
                ]
                if let last = lastCommitByPerson[identity] {
                    properties["core:lastCommit"] =
                        .string(ISO8601DateFormatter().string(from: last))
                }
                changes.entities.append(EntityAssertion(
                    stableKey: personKey, kind: .person, repository: nil,
                    name: tally.name.isEmpty ? identity : tally.name,
                    properties: properties,
                    supportedBy: Array(tally.supportedBy.prefix(1))))
            }
            changes.relationships.append(RelationshipAssertion(
                source: StableKeys.file(repoID, path), target: personKey,
                kind: .authoredBy, layer: .derived,
                properties: [
                    "core:commitCount": .int(Int64(tally.commits)),
                    "core:lastTouched": .string(
                        ISO8601DateFormatter().string(from: tally.lastTouched)),
                ],
                supportedBy: tally.supportedBy))

            let share = Double(tally.commits) / Double(perFileTotal[path] ?? 1)
            if share >= Self.ownershipThreshold,
               share > (dominant[path]?.share ?? 0) {
                dominant[path] = (identity, share, tally.supportedBy)
            }
        }

        // Inferred: one author holds enough of a file's history to be
        // called its owner. Everything else is left unowned on
        // purpose — "nobody clearly owns this" is the finding.
        for (path, owner) in dominant.sorted(by: { $0.key < $1.key }) {
            changes.relationships.append(RelationshipAssertion(
                source: StableKeys.file(repoID, path),
                target: StableKeys.person(owner.identity),
                kind: .ownedBy, layer: .inferred,
                properties: ["core:ownershipShare": .double(owner.share)],
                supportedBy: owner.supportedBy))
        }

        // Retract the previous round wholesale: counts change on every
        // commit, so an edge's identity includes its count and stale
        // ones would otherwise pile up revision after revision.
        for kind in [RelationshipKind.authoredBy, .ownedBy] {
            for existing in try store.relationships(kind: kind, at: .current) {
                changes.retractRelationships.append(existing.id)
            }
        }

        guard !changes.relationships.isEmpty else { return nil }
        return try store.commit(
            changes,
            note: "ownership \(displayName): \(assertedPeople.count) people, " +
                  "\(byPair.count) file-author pairs, \(dominant.count) owned")
    }
}

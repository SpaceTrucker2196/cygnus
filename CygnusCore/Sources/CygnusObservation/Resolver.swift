import Foundation
import CygnusGraph
import CygnusProviders

// Entity resolution: turns literal observations into graph assertions.
// This is the boundary where evidence becomes model — every assertion
// carries provenance back to the observations that support it.
//
// Stable keys (docs/architecture.md):
//   phys:repo:<repo>                       repository
//   phys:dir:<repo>/<path>                 directory
//   phys:file:<repo>/<path>                file
//   <lang>:decl:<repo>/<path>#<declPath>   declaration (file-scoped)
//   <lang>:module:<name>                   imported module (shared)

public struct FileObservations: Sendable {
    public let file: SnapshotFile
    public let language: String
    public let observations: [(id: ObservationID, observation: Observation)]
    public init(file: SnapshotFile, language: String,
                observations: [(id: ObservationID, observation: Observation)]) {
        self.file = file
        self.language = language
        self.observations = observations
    }
}

public enum StableKeys {
    public static func repository(_ repo: RepositoryID) -> StableKey {
        StableKey("phys:repo:\(repo.raw)")
    }
    public static func directory(_ repo: RepositoryID, _ path: String) -> StableKey {
        StableKey("phys:dir:\(repo.raw)/\(path)")
    }
    public static func file(_ repo: RepositoryID, _ path: String) -> StableKey {
        StableKey("phys:file:\(repo.raw)/\(path)")
    }
    public static func declaration(_ repo: RepositoryID, language: String,
                                   path: String, declPath: String) -> StableKey {
        StableKey("\(language):decl:\(repo.raw)/\(path)#\(declPath)")
    }
    public static func module(language: String, name: String) -> StableKey {
        StableKey("\(language):module:\(name)")
    }
}

public enum Resolver {
    /// Build assertions for a set of files (full snapshot or the
    /// changed subset). Directory and repository entities are always
    /// derived from the full manifest so physical containment stays
    /// complete. `renamedFrom` (new path → old path) threads identity
    /// across detected moves: the new file entity records where its
    /// content evidently came from.
    public static func resolve(repository: RepositoryID,
                               displayName: String,
                               manifest: SnapshotManifest,
                               files: [FileObservations],
                               renamedFrom: [String: String] = [:]) -> RevisionChanges {
        var changes = RevisionChanges()
        var assertedKeys = Set<StableKey>()

        func assert(_ entity: EntityAssertion) {
            guard assertedKeys.insert(entity.stableKey).inserted else { return }
            changes.entities.append(entity)
        }

        // Repository root.
        let repoKey = StableKeys.repository(repository)
        assert(EntityAssertion(stableKey: repoKey, kind: .repository,
                               repository: repository, name: displayName))

        // Directories + files + physical containment, from the manifest.
        for file in manifest.files {
            let components = file.path.split(separator: "/").map(String.init)
            var parentKey = repoKey
            var dirPath = ""
            for dir in components.dropLast() {
                dirPath = dirPath.isEmpty ? dir : "\(dirPath)/\(dir)"
                let dirKey = StableKeys.directory(repository, dirPath)
                assert(EntityAssertion(
                    stableKey: dirKey, kind: .directory, repository: repository,
                    name: dir,
                    anchors: [SourceAnchor(path: dirPath, blob: BlobHash(""), range: nil)]))
                changes.relationships.append(RelationshipAssertion(
                    source: parentKey, target: dirKey, kind: .containsPhysical,
                    layer: .observed))
                parentKey = dirKey
            }
            let fileKey = StableKeys.file(repository, file.path)
            var props: PropertyBag = ["core:size": .int(file.size)]
            if let hint = file.languageHint { props["core:language"] = .string(hint) }
            if let origin = renamedFrom[file.path] { props["core:renamedFrom"] = .string(origin) }
            assert(EntityAssertion(
                stableKey: fileKey, kind: .file, repository: repository,
                name: components.last ?? file.path, properties: props,
                anchors: [SourceAnchor(path: file.path, blob: file.blob, range: nil)]))
            changes.relationships.append(RelationshipAssertion(
                source: parentKey, target: fileKey, kind: .containsPhysical,
                layer: .observed))
        }

        // Declarations + imports, from observations.
        for fileObs in files {
            let fileKey = StableKeys.file(repository, fileObs.file.path)
            let lang = fileObs.language

            // All declared paths in this file, so declares edges can
            // attach to the deepest ancestor that actually exists —
            // extension members reference types declared elsewhere.
            let declaredPaths = Set(fileObs.observations.compactMap { _, obs -> String? in
                guard obs.kind == .declaration,
                      case .string(let path)? = obs.payload[ObservationPayload.declPath]
                else { return nil }
                return path
            })

            func lexicalParentKey(of declPath: String) -> StableKey {
                var components = declPath.split(separator: ".").dropLast()
                while !components.isEmpty {
                    let candidate = components.joined(separator: ".")
                    if declaredPaths.contains(candidate) {
                        return StableKeys.declaration(
                            repository, language: lang,
                            path: fileObs.file.path, declPath: candidate)
                    }
                    components = components.dropLast()
                }
                return fileKey
            }

            for (obsID, obs) in fileObs.observations {
                switch obs.kind {
                case .declaration:
                    guard case .string(let name)? = obs.payload[ObservationPayload.name],
                          case .string(let kindRaw)? = obs.payload[ObservationPayload.declKind],
                          case .string(let declPath)? = obs.payload[ObservationPayload.declPath]
                    else { continue }
                    let key = StableKeys.declaration(
                        repository, language: lang, path: fileObs.file.path, declPath: declPath)
                    assert(EntityAssertion(
                        stableKey: key, kind: EntityKind(kindRaw), repository: repository,
                        name: name,
                        anchors: obs.file.range.map { [SourceAnchor(path: obs.file.path, blob: obs.file.blob, range: $0)] } ?? [obs.file],
                        supportedBy: [obsID]))
                    changes.relationships.append(RelationshipAssertion(
                        source: lexicalParentKey(of: declPath), target: key, kind: .declares,
                        layer: .observed, supportedBy: [obsID]))

                case .importStatement:
                    guard case .string(let module)? = obs.payload[ObservationPayload.module]
                    else { continue }
                    let moduleKey = StableKeys.module(language: lang, name: module)
                    assert(EntityAssertion(
                        stableKey: moduleKey, kind: .module, repository: nil,
                        name: module, supportedBy: [obsID]))
                    changes.relationships.append(RelationshipAssertion(
                        source: fileKey, target: moduleKey, kind: .imports,
                        layer: .observed, supportedBy: [obsID]))

                default:
                    continue
                }
            }
        }

        return changes
    }
}

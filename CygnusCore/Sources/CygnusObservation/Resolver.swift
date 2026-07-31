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
    /// A build target is scoped to the file that declares it: two
    /// Makefiles may both define `all`, and they are not the same
    /// thing.
    public static func buildTarget(_ repo: RepositoryID, path: String,
                                   name: String) -> StableKey {
        StableKey("build:target:\(repo.raw)/\(path)#\(name)")
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

        // Build-dependency resolution needs to know what exists before
        // it can tell a real path from an unexpanded variable, and
        // which names are sibling targets in the same build file. Both
        // are one pass, done up front.
        let manifestPaths = Set(manifest.files.map(\.path))
        var buildTargets: [String: Set<String>] = [:]
        for fileObs in files {
            for (_, obs) in fileObs.observations where obs.kind == .buildRule {
                if case .string(let name)? = obs.payload[ObservationPayload.buildTarget] {
                    buildTargets[fileObs.file.path, default: []].insert(name)
                }
            }
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

                case .buildRule:
                    guard case .string(let target)? = obs.payload[ObservationPayload.buildTarget]
                    else { continue }
                    let targetKey = StableKeys.buildTarget(
                        repository, path: fileObs.file.path, name: target)
                    assert(EntityAssertion(
                        stableKey: targetKey, kind: .buildTarget, repository: repository,
                        name: target, anchors: [obs.file], supportedBy: [obsID]))
                    // The build file declares its targets, the same
                    // relation a source file has to its declarations.
                    changes.relationships.append(RelationshipAssertion(
                        source: fileKey, target: targetKey, kind: .declares,
                        layer: .observed, supportedBy: [obsID]))

                    guard case .string(let dependency)?
                            = obs.payload[ObservationPayload.buildDependency]
                    else { continue }
                    // Resolve the dependency against what the
                    // repository actually contains. A name that
                    // matches neither a file nor a sibling target is
                    // an unexpanded variable or a tool on PATH —
                    // recorded as an observation, but no edge is
                    // invented for it.
                    if let resolved = buildDependencyKey(
                        dependency, declaredIn: fileObs.file.path,
                        repository: repository, paths: manifestPaths,
                        siblingTargets: buildTargets[fileObs.file.path] ?? []) {
                        changes.relationships.append(RelationshipAssertion(
                            source: targetKey, target: resolved, kind: .builds,
                            layer: .observed, supportedBy: [obsID]))
                    }

                default:
                    continue
                }
            }
        }

        return changes
    }

    /// What a build dependency names, if anything in this repository.
    /// A sibling target wins over a file: `make test` where a `test`
    /// target *and* a `test/` path exist means the target.
    static func buildDependencyKey(_ dependency: String, declaredIn buildFile: String,
                                   repository: RepositoryID, paths: Set<String>,
                                   siblingTargets: Set<String>) -> StableKey? {
        if siblingTargets.contains(dependency) {
            return StableKeys.buildTarget(repository, path: buildFile, name: dependency)
        }
        // Paths in a build file are relative to its own directory.
        let directory = (buildFile as NSString).deletingLastPathComponent
        let candidates = directory.isEmpty
            ? [dependency]
            : ["\(directory)/\(dependency)", dependency]
        for candidate in candidates {
            let normalized = normalize(candidate)
            if paths.contains(normalized) {
                return StableKeys.file(repository, normalized)
            }
        }
        return nil
    }

    /// Collapse `./` and `a/../b` so a declared path matches a
    /// manifest path.
    static func normalize(_ path: String) -> String {
        var components: [String] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(component))
            }
        }
        return components.joined(separator: "/")
    }
}

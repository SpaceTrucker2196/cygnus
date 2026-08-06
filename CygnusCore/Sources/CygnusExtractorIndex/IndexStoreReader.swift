import Foundation
import IndexStoreDB
import CygnusGraph

// Reader over a compiled index store (-index-store-path artifacts).
// This is the reference-resolution enrichment: real definition ↔
// reference ↔ call edges, resolved by the compiler, not guessed from
// syntax. Optional by design — a repo without an index degrades to
// the swift-syntax baseline (docs/spikes/indexstoredb.md).
//
// An actor because IndexStoreDB's C++ core is wrapped conservatively:
// queries are documented thread-safe, but cygnus is strict-
// concurrency everywhere and one serialized reader per store is
// plenty for an enrichment pass.

public actor IndexStoreReader {
    /// One symbol occurrence, in cygnus vocabulary. Literal facts:
    /// "USR X occurs at path:line with roles [definition|call|…]".
    public struct Occurrence: Sendable, Equatable {
        public let usr: String
        public let name: String
        public let path: String
        public let line: Int
        public let column: Int
        public let isDefinition: Bool
        public let isReference: Bool
        public let isCall: Bool
    }

    private let db: IndexStoreDB

    /// Open a raw index store. `storePath` is the compiler's
    /// -index-store-path directory (units/ + records/); the
    /// acceleration database lands in `databasePath` (caller-owned
    /// scratch). Throws when the store or libIndexStore is missing.
    public init(storePath: String, databasePath: String) throws {
        guard let libPath = Self.libIndexStorePath() else {
            throw IndexReaderError.libIndexStoreNotFound
        }
        self.db = try IndexStoreDB(
            storePath: storePath,
            databasePath: databasePath,
            library: IndexStoreLibrary(dylibPath: libPath),
            listenToUnitEvents: false)
        db.pollForUnitChangesAndWait()
    }

    /// All occurrences of symbols with this exact name.
    public func occurrences(ofName name: String) -> [Occurrence] {
        db.canonicalOccurrences(ofName: name).flatMap { canonical in
            db.occurrences(ofUSR: canonical.symbol.usr,
                           roles: [.definition, .reference, .call])
                .map(Self.convert)
        }
    }

    /// Everything that references (or calls) the symbol with `usr`.
    public func references(toUSR usr: String) -> [Occurrence] {
        db.occurrences(ofUSR: usr, roles: [.reference, .call]).map(Self.convert)
    }

    /// One cross-file reference: `fromPath` (repo-relative) uses
    /// `symbolName`, which is defined in `toPath` (repo-relative).
    /// `line` is where the reference occurs; `defLine` is where the
    /// symbol is defined — enough to map both ends to the enclosing
    /// declaration for symbol-level edges.
    public struct FileReference: Sendable, Equatable {
        public let fromPath: String
        public let toPath: String
        public let symbolUSR: String
        public let symbolName: String
        public let line: Int
        public let column: Int
        public let defLine: Int
        /// The compiler marked this occurrence a **call**, not merely a
        /// mention. Keeping the two apart is what lets a caller graph
        /// honestly claim to be one: "X references Y" and "X calls Y"
        /// are different facts, and collapsing them makes the stronger
        /// claim on the weaker evidence.
        public let isCall: Bool
    }

    /// Symbol-name sweep bound — a runaway store must not turn
    /// enrichment into the memory story again.
    public static let symbolNameCap = 50_000

    /// All cross-file references between files under `repoRoot`:
    /// for every symbol defined in the repo, each reference from a
    /// *different* repo file. Same-file references are structure, not
    /// architecture, and are skipped.
    public func fileReferences(repoRoot: URL) -> [FileReference] {
        let rootPath = repoRoot.standardizedFileURL.path + "/"
        func relative(_ path: String) -> String? {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard standardized.hasPrefix(rootPath) else { return nil }
            let rel = String(standardized.dropFirst(rootPath.count))
            return rel.hasPrefix(".build/") ? nil : rel
        }

        var result: [FileReference] = []
        var seenUSRs = Set<String>()
        for name in db.allSymbolNames().prefix(Self.symbolNameCap) {
            for canonical in db.canonicalOccurrences(ofName: name) {
                let usr = canonical.symbol.usr
                guard seenUSRs.insert(usr).inserted,
                      canonical.roles.contains(.definition),
                      let definedIn = relative(canonical.location.path)
                else { continue }
                let defLine = canonical.location.line
                for occurrence in db.occurrences(ofUSR: usr, roles: [.reference, .call]) {
                    guard let fromPath = relative(occurrence.location.path),
                          fromPath != definedIn
                    else { continue }
                    result.append(FileReference(
                        fromPath: fromPath, toPath: definedIn,
                        symbolUSR: usr, symbolName: canonical.symbol.name,
                        line: occurrence.location.line,
                        column: occurrence.location.utf8Column,
                        defLine: defLine,
                        isCall: occurrence.roles.contains(.call)))
                }
            }
        }
        return result
    }

    /// The compiled index store for a repository, if a build has
    /// produced one. SPM keeps it in-tree; an Xcode project keeps it
    /// in DerivedData, outside the repo entirely. In-tree wins — it is
    /// unambiguously this checkout's.
    public static func storePath(under root: URL) -> String? {
        packageStorePath(under: root) ?? derivedDataStorePath(under: root)
    }

    /// The SPM index store for a package checkout, if a build has
    /// produced one. Root package and first-level nested packages.
    public static func packageStorePath(under root: URL) -> String? {
        let fm = FileManager.default
        var packageDirs = [root]
        if let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) {
            packageDirs += entries.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
        }
        for package in packageDirs {
            let build = package.appendingPathComponent(".build")
            guard let triples = try? fm.contentsOfDirectory(atPath: build.path) else { continue }
            for triple in triples.sorted() {
                let store = build.appendingPathComponent("\(triple)/debug/index/store")
                if fm.fileExists(atPath: store.appendingPathComponent("v5").path)
                    || fm.fileExists(atPath: store.path) {
                    return store.path
                }
            }
        }
        return nil
    }

    /// The Xcode index store for a project checkout, if a build has
    /// produced one. Xcode writes it to DerivedData — outside the
    /// repo, under a name-plus-hash directory — so the repo itself
    /// carries no trace of it. The mapping back is each build
    /// directory's `info.plist`, whose `WorkspacePath` names the
    /// `.xcodeproj`/`.xcworkspace` it was built from; a directory
    /// belongs to this repo when that path lies inside `root`.
    ///
    /// Two containers are searched: Xcode's default location, and
    /// `<root>/DerivedData` for the "relative to workspace" build
    /// setting. Most recently accessed wins when a repo has several
    /// (renamed project, multiple workspaces).
    /// A place Xcode may keep build directories. `shared` marks a
    /// container holding every project's builds — there, a directory
    /// must prove it belongs to this repo before we read it.
    public struct DerivedDataContainer: Sendable {
        public let url: URL
        public let shared: Bool
        public init(url: URL, shared: Bool) {
            self.url = url
            self.shared = shared
        }
    }

    public static func defaultDerivedDataContainers(under root: URL) -> [DerivedDataContainer] {
        [DerivedDataContainer(
            url: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/Xcode/DerivedData"),
            shared: true),
         DerivedDataContainer(
            url: root.appendingPathComponent("DerivedData"), shared: false)]
    }

    public static func derivedDataStorePath(
        under root: URL,
        containers: [DerivedDataContainer]? = nil) -> String? {
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path
        let containers = containers ?? defaultDerivedDataContainers(under: root)

        var candidates: [(store: String, accessed: Date)] = []
        for entry in containers {
            let container = entry.url
            // "Relative to workspace" may write the store directly in
            // the container, with no per-project directory below it.
            if !entry.shared {
                let store = container.appendingPathComponent("Index.noindex/DataStore")
                if fm.fileExists(atPath: store.path) {
                    let accessed = (try? store.resourceValues(
                        forKeys: [.contentModificationDateKey]).contentModificationDate)
                    candidates.append((store.path, accessed ?? .distantPast))
                }
            }
            guard let builds = try? fm.contentsOfDirectory(
                at: container, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { continue }

            for build in builds {
                guard (try? build.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                else { continue }
                let store = build.appendingPathComponent("Index.noindex/DataStore")
                guard fm.fileExists(atPath: store.path) else { continue }

                let info = plist(at: build.appendingPathComponent("info.plist"))
                // In a shared container a build directory is only
                // ours if its workspace lives under root. Under
                // <root>/DerivedData it is ours by construction — and
                // that layout may write no info.plist at all.
                if entry.shared {
                    guard let workspace = info?["WorkspacePath"] as? String,
                          isContained(URL(fileURLWithPath: workspace).standardizedFileURL.path,
                                      in: rootPath)
                    else { continue }
                }
                let accessed = info?["LastAccessedDate"] as? Date
                    ?? (try? store.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate)
                    ?? .distantPast
                candidates.append((store.path, accessed))
            }
        }
        return candidates.max(by: { $0.accessed < $1.accessed })?.store
    }

    private static func plist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)) as? [String: Any]
    }

    /// Path containment on component boundaries — a plain `hasPrefix`
    /// would let `/projects/nighthawk-iOS-old` match `/projects/nighthawk-iOS`.
    private static func isContained(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func convert(_ occurrence: SymbolOccurrence) -> Occurrence {
        Occurrence(
            usr: occurrence.symbol.usr,
            name: occurrence.symbol.name,
            path: occurrence.location.path,
            line: occurrence.location.line,
            column: occurrence.location.utf8Column,
            isDefinition: occurrence.roles.contains(.definition),
            isReference: occurrence.roles.contains(.reference),
            isCall: occurrence.roles.contains(.call))
    }

    /// libIndexStore ships in the active toolchain next to swiftc.
    static func libIndexStorePath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "swiftc"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let swiftc = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !swiftc.isEmpty else { return nil }
        // …/usr/bin/swiftc → …/usr/lib/libIndexStore.dylib
        let lib = URL(fileURLWithPath: swiftc)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/libIndexStore.dylib").path
        return FileManager.default.fileExists(atPath: lib) ? lib : nil
    }
}

public enum IndexReaderError: Error, Equatable {
    case libIndexStoreNotFound
}

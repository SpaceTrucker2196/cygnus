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

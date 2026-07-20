import Testing
import Foundation
import CygnusGraph
@testable import CygnusProviders

@Suite struct ProviderTests {
    func makeFixtureRepo() throws -> (root: URL, cas: ContentStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-provider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".build"), withIntermediateDirectories: true)
        try "import B\n".write(to: dir.appendingPathComponent("Sources/A.swift"),
                               atomically: true, encoding: .utf8)
        try "print('hi')\n".write(to: dir.appendingPathComponent("tool.py"),
                                  atomically: true, encoding: .utf8)
        try "junk".write(to: dir.appendingPathComponent(".build/artifact"),
                         atomically: true, encoding: .utf8)
        let cas = try ContentStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-cas-\(UUID().uuidString)"))
        return (dir, cas)
    }

    @Test func contentStoreRoundTripsAndDedupes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-cas-\(UUID().uuidString)")
        let cas = try ContentStore(root: dir)
        let data = Data("hello graph".utf8)
        let blob = try cas.store(data)
        #expect(cas.contains(blob))
        #expect(try cas.read(blob) == data)
        // Idempotent.
        #expect(try cas.store(data) == blob)
        // Fan-out layout: cas/ab/cdef...
        #expect(cas.url(for: blob).deletingLastPathComponent().lastPathComponent
                == String(blob.raw.prefix(2)))
    }

    @Test func localFSSnapshotCapturesSourcesSkipsBuildProducts() throws {
        let (root, cas) = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try LocalFSProvider(root: root, contentStore: cas).snapshot()

        let paths = manifest.files.map(\.path)
        #expect(paths.contains("Sources/A.swift"))
        #expect(paths.contains("tool.py"))
        #expect(!paths.contains(where: { $0.hasPrefix(".build") }))

        let swiftFile = try #require(manifest.file(at: "Sources/A.swift"))
        #expect(swiftFile.languageHint == "swift")
        #expect(try cas.read(swiftFile.blob) == Data("import B\n".utf8))
    }

    @Test func manifestDiffDetectsAddRemoveModify() throws {
        let (root, cas) = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = LocalFSProvider(root: root, contentStore: cas)
        let first = try provider.snapshot()

        try "import B\nimport C\n".write(to: root.appendingPathComponent("Sources/A.swift"),
                                         atomically: true, encoding: .utf8)
        try "def x(): pass\n".write(to: root.appendingPathComponent("new.py"),
                                    atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("tool.py"))
        let second = try provider.snapshot()

        let diff = ManifestDiff.between(first, second)
        #expect(diff.added.map(\.path) == ["new.py"])
        #expect(diff.removed.map(\.path) == ["tool.py"])
        #expect(diff.modified.map(\.path) == ["Sources/A.swift"])

        // Same tree diffed against itself is empty (idempotent snapshots).
        #expect(ManifestDiff.between(second, try provider.snapshot()).isEmpty)
    }
}

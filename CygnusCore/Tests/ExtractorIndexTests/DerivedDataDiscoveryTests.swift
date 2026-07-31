import Testing
import Foundation
@testable import CygnusExtractorIndex

// Finding an Xcode project's index store. SPM keeps it in-tree; Xcode
// keeps it in DerivedData under a name-plus-hash directory, tied back
// to the repo only by info.plist's WorkspacePath. Hermetic: every
// layout here is built in a temp directory.

@Suite struct DerivedDataDiscoveryTests {
    private let fm = FileManager.default

    private func scratch() throws -> URL {
        let url = fm.temporaryDirectory
            .appendingPathComponent("cygnus-dd-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// One DerivedData build directory: a DataStore, plus the
    /// info.plist Xcode writes to name the workspace it built.
    @discardableResult
    private func build(_ name: String, in container: URL,
                       workspace: String?, accessed: Date? = nil) throws -> URL {
        let dir = container.appendingPathComponent(name)
        let store = dir.appendingPathComponent("Index.noindex/DataStore")
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        if let workspace {
            var info: [String: Any] = ["WorkspacePath": workspace]
            if let accessed { info["LastAccessedDate"] = accessed }
            let data = try PropertyListSerialization.data(
                fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: dir.appendingPathComponent("info.plist"))
        }
        return store
    }

    /// The temp directory is reached through a symlink (/var →
    /// /private/var), and directory enumeration resolves it — compare
    /// on resolved paths or every expectation fails on the prefix.
    private func isSamePath(_ found: String?, _ expected: URL) -> Bool {
        guard let found else { return false }
        return URL(fileURLWithPath: found).resolvingSymlinksInPath().path
            == expected.resolvingSymlinksInPath().path
    }

    private func containers(shared: URL, repo: URL) -> [IndexStoreReader.DerivedDataContainer] {
        [.init(url: shared, shared: true),
         .init(url: repo.appendingPathComponent("DerivedData"), shared: false)]
    }

    @Test func findsTheStoreForThisRepoInTheSharedContainer() throws {
        let root = try scratch()
        let repo = root.appendingPathComponent("nighthawk-iOS")
        let shared = root.appendingPathComponent("DerivedData")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)

        let mine = try build("Nighthawk-abcdef", in: shared,
                             workspace: repo.appendingPathComponent("Nighthawk.xcodeproj").path)
        try build("Otter-ghijkl", in: shared,
                  workspace: root.appendingPathComponent("otter/Otter.xcodeproj").path)

        let found = IndexStoreReader.derivedDataStorePath(
            under: repo, containers: containers(shared: shared, repo: repo))
        #expect(isSamePath(found, mine))
    }

    /// A sibling whose path merely starts with ours is a different
    /// repo — containment is on component boundaries.
    @Test func doesNotClaimASiblingRepoWithAPrefixName() throws {
        let root = try scratch()
        let repo = root.appendingPathComponent("nighthawk-iOS")
        let shared = root.appendingPathComponent("DerivedData")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        try build("Nighthawk-old", in: shared,
                  workspace: root.appendingPathComponent("nighthawk-iOS-old/N.xcodeproj").path)

        let found = IndexStoreReader.derivedDataStorePath(
            under: repo, containers: containers(shared: shared, repo: repo))
        #expect(found == nil)
    }

    /// Several builds of the same repo: the one Xcode touched last.
    @Test func prefersTheMostRecentlyAccessedBuild() throws {
        let root = try scratch()
        let repo = root.appendingPathComponent("nighthawk-iOS")
        let shared = root.appendingPathComponent("DerivedData")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)

        try build("Nighthawk-old", in: shared,
                  workspace: repo.appendingPathComponent("Nighthawk.xcodeproj").path,
                  accessed: Date(timeIntervalSince1970: 1_000_000))
        let newer = try build("Nighthawk-new", in: shared,
                              workspace: repo.appendingPathComponent("Nighthawk.xcworkspace").path,
                              accessed: Date(timeIntervalSince1970: 2_000_000))

        let found = IndexStoreReader.derivedDataStorePath(
            under: repo, containers: containers(shared: shared, repo: repo))
        #expect(isSamePath(found, newer))
    }

    /// "Relative to workspace" writes into the repo and may leave no
    /// info.plist — that layout is ours by construction.
    @Test func findsAnInRepoStoreWithoutAnInfoPlist() throws {
        let root = try scratch()
        let repo = root.appendingPathComponent("nighthawk-iOS")
        let shared = root.appendingPathComponent("DerivedData")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        let store = try build("Nighthawk", in: repo.appendingPathComponent("DerivedData"),
                              workspace: nil)

        let found = IndexStoreReader.derivedDataStorePath(
            under: repo, containers: containers(shared: shared, repo: repo))
        #expect(isSamePath(found, store))
    }

    @Test func returnsNilWhenNothingHasBeenBuilt() throws {
        let root = try scratch()
        let repo = root.appendingPathComponent("nighthawk-iOS")
        let shared = root.appendingPathComponent("DerivedData")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)

        let found = IndexStoreReader.derivedDataStorePath(
            under: repo, containers: containers(shared: shared, repo: repo))
        #expect(found == nil)
    }
}

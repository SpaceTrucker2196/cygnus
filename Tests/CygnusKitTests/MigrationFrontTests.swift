import Testing
import Foundation
@testable import CygnusKit

// A half-finished migration, made visible. The pair of modules is
// named by a person, so these tests are about classification and
// counting — never about guessing which modules belong together.

@Suite struct MigrationFrontTests {
    private func file(_ name: String) -> GraphSnapshot.Node {
        GraphSnapshot.Node(id: "phys:file:r/\(name)", kind: "core:file",
                           label: name, path: "Sources/\(name)")
    }

    private func module(_ name: String) -> GraphSnapshot.Node {
        GraphSnapshot.Node(id: "swift:module:\(name)", kind: "core:module", label: name)
    }

    private func imports(_ file: String, _ module: String) -> GraphSnapshot.Edge {
        GraphSnapshot.Edge(from: "phys:file:r/\(file)", to: "swift:module:\(module)",
                           kind: "core:imports")
    }

    /// Old → New, mid-migration: one moved, one has not, one uses
    /// both, one is uninvolved.
    private var snapshot: GraphSnapshot {
        GraphSnapshot(
            nodes: [file("Moved.swift"), file("Legacy.swift"), file("Both.swift"),
                    file("Elsewhere.swift"), module("OldKit"), module("NewKit"),
                    module("Foundation")],
            edges: [imports("Moved.swift", "NewKit"),
                    imports("Legacy.swift", "OldKit"),
                    imports("Both.swift", "OldKit"), imports("Both.swift", "NewKit"),
                    imports("Elsewhere.swift", "Foundation")])
    }

    private var front: GraphScene.MigrationFront {
        GraphScene.migrationFront(from: "swift:module:OldKit",
                                  to: "swift:module:NewKit", in: snapshot)
    }

    @Test func classifiesEachSideAndTheStraddlers() {
        #expect(front.stand["phys:file:r/Moved.swift"] == "Migrated")
        #expect(front.stand["phys:file:r/Legacy.swift"] == "Not migrated")
        #expect(front.stand["phys:file:r/Both.swift"] == "Straddling")
    }

    /// A file using neither module is absent, not labelled. Colouring
    /// it as part of the migration would be a lie.
    @Test func uninvolvedFilesAreNotClassified() {
        #expect(front.stand["phys:file:r/Elsewhere.swift"] == nil)
        #expect(front.total == 3)
    }

    @Test func countsAndProgressReflectTheFront() {
        #expect(front.migrated == 1)
        #expect(front.remaining == 1)
        #expect(front.straddling == 1)
        #expect(front.progress == 1.0 / 3.0)
    }

    /// A pair naming nothing reports no progress rather than 0% or
    /// 100%, both of which would read as a real answer.
    @Test func aPairThatNamesNothingHasNoProgress() {
        let empty = GraphScene.migrationFront(from: "swift:module:Absent",
                                              to: "swift:module:AlsoAbsent",
                                              in: snapshot)
        #expect(empty.total == 0)
        #expect(empty.progress == nil)
        #expect(empty.stand.isEmpty)
    }

    /// A finished migration is all-migrated, which is how you know to
    /// delete the old module.
    @Test func aCompletedMigrationHasNothingLeft() {
        let done = GraphSnapshot(
            nodes: [file("A.swift"), module("OldKit"), module("NewKit")],
            edges: [imports("A.swift", "NewKit")])
        let complete = GraphScene.migrationFront(from: "swift:module:OldKit",
                                                 to: "swift:module:NewKit", in: done)
        #expect(complete.progress == 1.0)
        #expect(complete.remaining == 0 && complete.straddling == 0)
    }

    /// The picker offers modules something actually imports, in a
    /// stable order — an unimported module names no migration.
    @Test func offersImportedModulesOnly() {
        let names = GraphScene.migratableModules(in: snapshot).map(\.label)
        #expect(names == ["Foundation", "NewKit", "OldKit"])
    }
}

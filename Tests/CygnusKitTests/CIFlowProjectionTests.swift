import Testing
import Foundation
@testable import CygnusKit

// Differential test: the flow built from the graph against the flow
// built by parsing the Makefile directly. They must agree before the
// second parser can be deleted, and this is what says whether they do
// — rather than someone squinting at an animation.

@Suite struct CIFlowProjectionTests {
    /// Index a real temp repo through the real engine, then project.
    /// A synthetic snapshot would only prove the projection agrees
    /// with my idea of the graph, not with the graph.
    private func indexed(makefile: String) async throws -> GraphSnapshot {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "int main(void){return 0;}\n".write(
            to: root.appendingPathComponent("src/main.c"),
            atomically: true, encoding: .utf8)
        try makefile.write(to: root.appendingPathComponent("Makefile"),
                           atomically: true, encoding: .utf8)

        let engine = WorkspaceGraphEngine(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-flow-ws-\(UUID().uuidString)"))
        var snapshot: GraphSnapshot?
        for try await event in engine.analyze(repoAt: root) {
            if case .finished(let result) = event { snapshot = result }
        }
        return try #require(snapshot)
    }

    private let makefile = """
        CC = clang
        .PHONY: all test clean

        all: app test

        app: src/main.c
        \t$(CC) -o app src/main.c

        test: app
        \t@./app --test
        \techo done

        clean:
        \trm -rf app
        """

    /// The structural claim: same nodes, same kinds, same layout
    /// positions, same edges. Labels included, because a chart whose
    /// labels changed is a chart that changed.
    @Test func theGraphProducesTheSameFlowAsParsingTheFile() async throws {
        let snapshot = try await indexed(makefile: makefile)
        let fromGraph = CIFlow.from(snapshot: snapshot, buildFile: "Makefile")
        let fromFile = MakeFlowBuilder.build(makefileText: makefile)

        #expect(fromGraph.source == fromFile.source)

        func described(_ flow: CIFlow) -> Set<String> {
            Set(flow.nodes.map { "\($0.kind.rawValue) \($0.label) @\($0.column),\($0.row)" })
        }
        let graphNodes = described(fromGraph)
        let fileNodes = described(fromFile)
        let onlyGraph = graphNodes.subtracting(fileNodes).sorted().joined(separator: ", ")
        let onlyFile = fileNodes.subtracting(graphNodes).sorted().joined(separator: ", ")
        #expect(graphNodes == fileNodes,
                "only in graph: [\(onlyGraph)]  only in file: [\(onlyFile)]")

        func describedEdges(_ flow: CIFlow) -> Set<String> {
            Set(flow.edges.map { "\($0.from)→\($0.to)" })
        }
        #expect(describedEdges(fromGraph) == describedEdges(fromFile))
    }

    /// The label the chart shows is derived in the projection, so the
    /// graph can keep the literal command. `$(CC)` must still read as
    /// `clang`, which is why recipes are expanded on the way in.
    @Test func stepLabelsAreProgramsNotWholeCommands() async throws {
        let snapshot = try await indexed(makefile: makefile)
        let flow = CIFlow.from(snapshot: snapshot, buildFile: "Makefile")
        let labels = Set(flow.nodes.filter { $0.kind == .action }.map(\.label))
        #expect(labels.contains("clang"), "expected the expanded compiler in \(labels)")
        #expect(labels.contains("rm"))
        #expect(!labels.contains { $0.contains(" ") }, "labels should be programs: \(labels)")
    }

    @Test func programSkipsEnvironmentAssignmentsAndPaths() {
        #expect(CIFlow.program(in: "clang -o app main.c") == "clang")
        #expect(CIFlow.program(in: "CGO_ENABLED=0 go build") == "go")
        #expect(CIFlow.program(in: "/usr/bin/env swift build") == "env")
        #expect(CIFlow.program(in: "./scripts/build.sh") == "build.sh")
    }

    /// A target the two sides deliberately disagree about: the graph
    /// expands `$(TARGET)` and drops `%.o`, because an entity needs a
    /// stable identity and a pattern rule describes a shape rather
    /// than a thing. The chart keeps both verbatim so its picture
    /// stays connected. Comparing those would be comparing two
    /// documented policies, not testing the projection.
    private func isPolicyDivergent(_ label: String) -> Bool {
        label.contains("$(") || label.contains("%") || label.contains("${")
    }

    /// The fixture proves the mechanism; real Makefiles prove it
    /// survives contact. These are the repositories the CI Flow view
    /// is actually used on.
    @Test(arguments: ["cygnus", "otter"])
    func realMakefilesProjectIdentically(repo: String) async throws {
        let path = ("~/projects/\(repo)/Makefile" as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let snapshot = try await indexed(makefile: text)
        let fromGraph = CIFlow.from(snapshot: snapshot, buildFile: "Makefile")
        let fromFile = MakeFlowBuilder.build(makefileText: text)

        // Compared by name and kind, not by row: once variable
        // targets are set aside the two sides number their remaining
        // rows differently, and row order is layout rather than
        // content.
        func described(_ flow: CIFlow) -> Set<String> {
            Set(flow.nodes
                .filter { !isPolicyDivergent($0.label) }
                .map { "\($0.kind.rawValue) \($0.label)" })
        }
        let onlyGraph = described(fromGraph).subtracting(described(fromFile))
            .sorted().joined(separator: ", ")
        let onlyFile = described(fromFile).subtracting(described(fromGraph))
            .sorted().joined(separator: ", ")
        #expect(described(fromGraph) == described(fromFile),
                "\(repo) — only in graph: [\(onlyGraph)]  only in file: [\(onlyFile)]")
    }

    /// sloth is the case where the two sides genuinely disagree, and
    /// pinning it is more useful than filtering it away. Its Makefile
    /// builds `$(TARGET)`, so:
    ///
    ///   - the graph expands the variable and names the target
    ///     `sloth`, because an entity needs an identity a later
    ///     revision can match;
    ///   - the chart keeps `$(TARGET)` verbatim, because commit
    ///     9342eea decided a variable target should read as written.
    ///
    /// Both are defensible and they cannot both be shown. Swapping the
    /// chart onto the graph therefore changes what a user sees, which
    /// is a decision to make deliberately rather than discover. If
    /// this test fails, that decision was made — check it was on
    /// purpose.
    @Test func slothShowsTheExpansionDisagreement() async throws {
        let path = ("~/projects/sloth/Makefile" as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let snapshot = try await indexed(makefile: text)
        let graphLabels = Set(CIFlow.from(snapshot: snapshot, buildFile: "Makefile")
            .nodes.map(\.label))
        let fileLabels = Set(MakeFlowBuilder.build(makefileText: text).nodes.map(\.label))

        // The graph names what actually gets built.
        #expect(graphLabels.contains("sloth"))
        #expect(!graphLabels.contains("$(TARGET)"))
        // The chart names what the file says.
        #expect(fileLabels.contains("$(TARGET)"))
        #expect(!fileLabels.contains("sloth"))
        // And everything outside that disagreement matches, which is
        // what makes the swap a decision rather than a rewrite.
        let plain = { (labels: Set<String>) in
            labels.filter { !self.isPolicyDivergent($0)
                && !["sloth", "sloth_test", "MAKE"].contains($0) }
        }
        #expect(plain(graphLabels) == plain(fileLabels))
    }

    @Test func aSnapshotWithNoBuildTargetsMakesAnEmptyFlow() {
        let flow = CIFlow.from(snapshot: GraphSnapshot(nodes: [], edges: []))
        #expect(flow.isEmpty)
    }
}

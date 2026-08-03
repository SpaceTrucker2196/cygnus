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

    /// The fixture proves the mechanism; real Makefiles prove it
    /// survives contact. These are the repositories the CI Flow view
    /// is actually used on. sloth is the variable-and-pattern-heavy
    /// one: it joined this set on 2026-08-03, when the verbatim
    /// spelling became a property and pattern rules became facts.
    @Test(arguments: ["cygnus", "otter", "sloth"])
    func realMakefilesProjectIdentically(repo: String) async throws {
        let path = ("~/projects/\(repo)/Makefile" as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let snapshot = try await indexed(makefile: text)
        let fromGraph = CIFlow.from(snapshot: snapshot, buildFile: "Makefile")
        let fromFile = MakeFlowBuilder.build(makefileText: text)

        // Compared by name and kind, not by row: the two sides split
        // multi-target rule lines differently, so row numbering is
        // layout rather than content.
        func described(_ flow: CIFlow) -> Set<String> {
            Set(flow.nodes.map { "\($0.kind.rawValue) \($0.label)" })
        }
        let onlyGraph = described(fromGraph).subtracting(described(fromFile))
            .sorted().joined(separator: ", ")
        let onlyFile = described(fromFile).subtracting(described(fromGraph))
            .sorted().joined(separator: ", ")
        #expect(described(fromGraph) == described(fromFile),
                "\(repo) — only in graph: [\(onlyGraph)]  only in file: [\(onlyFile)]")
    }

    /// The expansion-versus-spelling decision, settled 2026-08-03:
    /// the entity's identity is the expansion (`sloth`, so a later
    /// revision can match it), and the chart reads as the file is
    /// written (`$(TARGET)`, kept as `core:buildTargetVerbatim`).
    /// Pattern rules are in the graph too, flagged — `%.o` is a
    /// declared shape, not an artifact, but it is still a row.
    @Test func theEntityIsTheExpansionAndTheChartIsTheSpelling() async throws {
        let path = ("~/projects/sloth/Makefile" as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let snapshot = try await indexed(makefile: text)

        // The graph names what actually gets built…
        let entities = snapshot.nodes.filter { $0.kind == "core:buildTarget" }
        #expect(entities.contains { $0.label == "sloth" })
        #expect(!entities.contains { $0.label == "$(TARGET)" })
        // …and remembers the spelling and the shape.
        let sloth = entities.first { $0.label == "sloth" }
        #expect(sloth?.attributes["core:buildTargetVerbatim"] == "$(TARGET)")
        let pattern = entities.first { $0.label == "%.o" }
        #expect(pattern?.attributes["core:buildPattern"] == "true")

        // The chart shows the file's own words.
        let chartLabels = Set(CIFlow.from(snapshot: snapshot, buildFile: "Makefile")
            .nodes.map(\.label))
        #expect(chartLabels.contains("$(TARGET)"))
        #expect(chartLabels.contains("%.o"))
        #expect(!chartLabels.contains("sloth"))
    }

    // MARK: - fastlane

    private func indexedFastfile(_ text: String,
                                 workflow: (name: String, text: String)? = nil)
    async throws -> GraphSnapshot {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-lane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("fastlane"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try text.write(to: root.appendingPathComponent("fastlane/Fastfile"),
                       atomically: true, encoding: .utf8)
        if let workflow {
            let workflows = root.appendingPathComponent(".github/workflows")
            try FileManager.default.createDirectory(at: workflows,
                                                    withIntermediateDirectories: true)
            try workflow.text.write(to: workflows.appendingPathComponent(workflow.name),
                                    atomically: true, encoding: .utf8)
        }
        let engine = WorkspaceGraphEngine(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-lane-ws-\(UUID().uuidString)"))
        var snapshot: GraphSnapshot?
        for try await event in engine.analyze(repoAt: root) {
            if case .finished(let result) = event { snapshot = result }
        }
        return try #require(snapshot)
    }

    private let fastfile = """
        platform :ios do
          private_lane :setup do
            cocoapods
          end

          lane :beta do
            setup
            build_app
            upload_to_testflight
          end
        end
        """

    /// Lanes project with the chart's own dialect: `lane:` ids, and a
    /// step naming another lane drawn as a call wired across to it.
    @Test func lanesProjectWithCallsWiredAcross() async throws {
        let snapshot = try await indexedFastfile(fastfile)
        let flow = CIFlow.from(snapshot: snapshot, buildFile: "fastlane/Fastfile")
        let fromFile = FastlaneFlowBuilder.build(
            info: FastlaneInfo(lanes: [], appfile: [], ciInvocations: []),
            fastfileText: fastfile)

        #expect(flow.source == .fastlane)
        func described(_ f: CIFlow) -> Set<String> {
            Set(f.nodes.map { "\($0.kind.rawValue) \($0.label)" })
        }
        let onlyGraph = described(flow).subtracting(described(fromFile))
            .sorted().joined(separator: ", ")
        let onlyFile = described(fromFile).subtracting(described(flow))
            .sorted().joined(separator: ", ")
        #expect(described(flow) == described(fromFile),
                "only in graph: [\(onlyGraph)]  only in file: [\(onlyFile)]")
        // The call edge is what makes the chart a pipeline rather than
        // a set of disconnected rows.
        #expect(flow.edges.contains { $0.to == "lane:setup" })
    }

    /// The half of the fastlane chart the graph could not produce
    /// until 2026-08-03: trigger nodes name the CI workflow file
    /// that invokes a lane. Workflows are extracted now
    /// (`core:ciInvocation` → `core:invokes`), so the two sides must
    /// draw the same trigger column — ids and edges included, because
    /// the build tracker matches on them.
    @Test func triggersComeFromWorkflowEvidenceInTheGraph() async throws {
        let snapshot = try await indexedFastfile(fastfile, workflow: (
            name: "deploy.yml",
            text: """
                jobs:
                  beta:
                    steps:
                      - run: bundle exec fastlane ios beta
                """))
        let flow = CIFlow.from(snapshot: snapshot, buildFile: "fastlane/Fastfile")
        let fromFile = FastlaneFlowBuilder.build(
            info: FastlaneInfo(lanes: [], appfile: [],
                               ciInvocations: ["deploy.yml: bundle exec fastlane ios beta"]),
            fastfileText: fastfile)

        let graphTriggers = flow.nodes.filter { $0.kind == .trigger }
        let fileTriggers = fromFile.nodes.filter { $0.kind == .trigger }
        #expect(graphTriggers == fileTriggers,
                "graph: \(graphTriggers)  file: \(fileTriggers)")
        #expect(graphTriggers.contains { $0.label == "deploy.yml" })
        #expect(flow.edges.contains { $0.from == "trigger:beta:deploy.yml"
                                      && $0.to == "lane:beta" })
        // The workflow names beta, not setup — no trigger is invented
        // for a lane it does not run.
        #expect(!flow.edges.contains { $0.to == "lane:setup"
                                       && $0.from.hasPrefix("trigger:") })
    }

    /// A Fastfile with no workflow evidence still charts — it just
    /// has no trigger column, exactly like the file parser given no
    /// CI invocations.
    @Test func noWorkflowsMeansNoTriggers() async throws {
        let snapshot = try await indexedFastfile(fastfile)
        let flow = CIFlow.from(snapshot: snapshot, buildFile: "fastlane/Fastfile")
        #expect(!flow.nodes.contains { $0.kind == .trigger })
    }

    @Test func aSnapshotWithNoBuildTargetsMakesAnEmptyFlow() {
        let flow = CIFlow.from(snapshot: GraphSnapshot(nodes: [], edges: []))
        #expect(flow.isEmpty)
    }
}

// The swap itself: once a repo has a snapshot, the chart the app
// shows is the graph's projection, not the capability scan's parse.
@Suite @MainActor struct CIFlowSwapTests {
    @Test func theStoreChartsFromTheGraphOnceAnalyzed() throws {
        let store = WorkspaceStore(
            engine: FixtureGraphEngine(),
            persistence: WorkspacePersistence(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("cygnus-swap-\(UUID().uuidString).json")))
        let repo = RegisteredRepo(displayName: "fixture", pathHint: "/tmp/fixture",
                                  bookmark: Data())
        store.testInject(repo: repo)
        // Before analysis there is no snapshot and no capability scan
        // in this test, so there is nothing to chart.
        #expect(store.ciFlow(for: repo.id) == nil)

        let snapshot = GraphSnapshot(nodes: [
            GraphSnapshot.Node(id: "build:target:r/Makefile#all", kind: "core:buildTarget",
                               label: "all", path: "Makefile",
                               attributes: ["core:buildSystem": "make",
                                            "core:buildOrder": "0",
                                            "core:buildPhony": "true"]),
        ], edges: [])
        store.testApply(.finished(snapshot), to: repo.id)

        let flow = try #require(store.ciFlow(for: repo.id))
        #expect(flow.source == .make)
        #expect(flow.nodes.contains { $0.kind == .lane && $0.label == "all" })
        #expect(flow.nodes.contains { $0.kind == .trigger && $0.label == "make" })
    }
}

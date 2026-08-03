import Foundation

// Building the CI flow from the graph instead of from a second parse
// of the build file.
//
// Every visualization in cygnus is supposed to be a projection of the
// graph. The CI-flow chart has been the exception since it shipped —
// it re-parses Makefiles and Fastfiles itself, which is why
// `MakeFlowBuilder` and `CygnusExtractorBuild` both know how to read a
// Make rule. This is the replacement; the swap is deliberately not
// wired in yet (see docs/wiki/extractors.md).

extension CIFlow {
    /// The pipeline to chart, choosing the build file the way the
    /// capability scan always has: fastlane's flow when a Fastfile
    /// declared lanes, otherwise the root Makefile. Nil when the
    /// graph records neither.
    public static func projected(from snapshot: GraphSnapshot) -> CIFlow? {
        let targets = snapshot.nodes.filter { $0.kind == "core:buildTarget" }
        if let fastfile = targets
            .first(where: { $0.attributes["core:buildSystem"] == "fastlane" })?.path {
            let flow = from(snapshot: snapshot, buildFile: fastfile)
            if !flow.isEmpty { return flow }
        }
        for name in ["Makefile", "makefile", "GNUmakefile"] {
            let flow = from(snapshot: snapshot, buildFile: name)
            if !flow.isEmpty { return flow }
        }
        return nil
    }

    /// The build pipeline as recorded in the graph: `core:buildTarget`
    /// entities, their `core:buildSteps`, and the `core:builds` edges
    /// between them.
    ///
    /// Laid out exactly as `MakeFlowBuilder`/`FastlaneFlowBuilder` lay
    /// it out — one row per target, the target in column 1, its steps
    /// chained rightward — so the two can be compared and the older
    /// path retired without the picture changing.
    public static func from(snapshot: GraphSnapshot,
                            buildFile: String? = nil) -> CIFlow {
        // Declaration order, not stable-key order. Make's default
        // goal is the first target in the file, so a snapshot sorted
        // by key would not merely reshuffle rows — it would name the
        // wrong entry point.
        let targets = snapshot.nodes
            .filter { $0.kind == "core:buildTarget" }
            .filter { buildFile == nil || $0.path == buildFile }
            .sorted { a, b in
                let x = Int(a.attributes["core:buildOrder"] ?? "") ?? Int.max
                let y = Int(b.attributes["core:buildOrder"] ?? "") ?? Int.max
                return x == y ? a.label < b.label : x < y
            }
        guard !targets.isEmpty else { return CIFlow(nodes: [], edges: [], source: .make) }

        let system = targets.first?.attributes["core:buildSystem"] ?? "make"
        let source: CIFlow.Source = system == "fastlane" ? .fastlane : .make
        // The entity's identity is the expanded name; the row reads as
        // the file spells it. Both are in the graph, and the chart is
        // where the spelling belongs — a chart is for the person who
        // opens the build file next.
        func shown(_ node: GraphSnapshot.Node) -> String {
            node.attributes["core:buildTargetVerbatim"] ?? node.label
        }
        // Stable keys embed the declaring file and the name; the
        // renderer's ids are name-scoped, so map between them once.
        let nameByID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, shown($0)) })
        let names = Set(targets.map(shown))

        // Entry: the same rule the file parsers use — `all` when it
        // exists, otherwise whatever came first.
        let defaultGoal = targets.first { shown($0) == "all" }.map(shown) ?? shown(targets[0])

        // Fastlane triggers: workflow files whose command lines name a
        // lane, recorded as core:invokes edges pointing at it.
        let workflowByID = Dictionary(uniqueKeysWithValues:
            snapshot.nodes.filter { $0.kind == "core:file" }.map { ($0.id, $0) })

        // The two chart builders id their nodes differently, and the
        // build tracker matches on these, so the projection has to
        // speak whichever dialect the source uses.
        let prefix = source == .fastlane ? "lane:" : "target:"

        var nodes: [CIFlow.Node] = []
        var edges: [CIFlow.Edge] = []
        for (row, target) in targets.enumerated() {
            let label = shown(target)
            let targetID = "\(prefix)\(label)"
            nodes.append(CIFlow.Node(id: targetID, kind: .lane, label: label,
                                     column: 1, row: row))

            // A Makefile has one entry: its default goal. A Fastfile
            // has one trigger per CI workflow whose command line names
            // the lane — core:invokes edges from workflow file nodes.
            if source == .make, label == defaultGoal {
                let entryID = "goal:\(label)"
                let phony = target.attributes["core:buildPhony"] == "true"
                nodes.append(CIFlow.Node(id: entryID, kind: .trigger,
                                         label: phony ? "make" : "goal",
                                         column: 0, row: row))
                edges.append(CIFlow.Edge(from: entryID, to: targetID))
            }
            if source == .fastlane {
                let files = snapshot.edges
                    .filter { $0.kind == "core:invokes" && $0.to == target.id }
                    .compactMap { workflowByID[$0.from]?.label }
                for file in Set(files).sorted() {
                    let triggerID = "trigger:\(label):\(file)"
                    nodes.append(CIFlow.Node(id: triggerID, kind: .trigger, label: file,
                                             column: 0, row: row))
                    edges.append(CIFlow.Edge(from: triggerID, to: targetID))
                }
            }

            // target → target dependencies, in the direction the chart
            // draws them: what a target needs feeds into it.
            for edge in snapshot.edges
            where edge.kind == "core:builds" && edge.from == target.id {
                guard let dependency = nameByID[edge.to], names.contains(dependency) else {
                    continue
                }
                edges.append(CIFlow.Edge(from: "target:\(dependency)", to: targetID))
            }

            var previous = targetID
            for (index, step) in steps(of: target).enumerated() {
                // The graph holds the whole command, because that is
                // what the file says. The chart wants the program —
                // deriving it here keeps interpretation in the
                // projection, where it belongs.
                // A Makefile step is a command line, so the chart
                // wants its program. A fastlane step is already an
                // action name and must not be reduced further.
                let stepLabel = source == .fastlane ? step : program(in: step)
                // A step naming another lane is a call, drawn as one
                // and wired across to that lane.
                let isCall = source == .fastlane && names.contains(stepLabel)
                    && stepLabel != label
                let stepID = "\(targetID)#\(index):\(stepLabel)"
                nodes.append(CIFlow.Node(id: stepID, kind: isCall ? .laneCall : .action,
                                         label: stepLabel, column: 2 + index, row: row))
                edges.append(CIFlow.Edge(from: previous, to: stepID))
                if isCall {
                    edges.append(CIFlow.Edge(from: stepID, to: "\(prefix)\(stepLabel)"))
                }
                previous = stepID
            }
        }
        return CIFlow(nodes: nodes, edges: edges, source: source)
    }

    /// Ordered steps, split back out of the attribute bag.
    static func steps(of node: GraphSnapshot.Node) -> [String] {
        guard let joined = node.attributes["core:buildSteps"], !joined.isEmpty else { return [] }
        return joined.components(separatedBy: "\u{1f}").filter { !$0.isEmpty }
    }

    /// The program a command line invokes: its first word, with any
    /// leading `VAR=value` environment assignments skipped, and a
    /// path reduced to its basename. A variable the extractor could
    /// not resolve (`$(MAKE)` is make's own, never assigned in the
    /// file) reads as its name — the label is for a person.
    static func program(in command: String) -> String {
        var words = command.split(separator: " ").map(String.init)
        while let first = words.first, first.contains("="), !first.hasPrefix("-") {
            words.removeFirst()
        }
        guard var word = words.first else { return command }
        word = word.split(separator: "/").last.map(String.init) ?? word
        if word.hasPrefix("$(") || word.hasPrefix("${") {
            let name = String(word.dropFirst(2).prefix { $0 != ")" && $0 != "}" })
            if !name.isEmpty { return name }
        }
        return word
    }
}

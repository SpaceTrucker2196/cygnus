import Foundation

// A build/CI pipeline as a laid-out flowchart: entry → group → its
// ordered steps, with calls wired across. Two sources feed it —
// fastlane Fastfiles (trigger → lane → action) and Makefiles (goal →
// target → recipe command). Parsing is heuristic line-reading (never
// executed), enough to visualize every path the pipeline can take.

public struct CIFlow: Sendable, Equatable {
    /// What produced the flow — drives the legend wording.
    public enum Source: String, Sendable, Equatable { case fastlane, make }

    public enum NodeKind: String, Sendable, Equatable {
        case trigger    // fastlane: CI workflow · make: default/phony goal
        case lane       // fastlane: a lane · make: a target
        case action     // fastlane: an action · make: a recipe command
        case laneCall   // fastlane: sub-lane call · make: prerequisite target
    }

    public struct Node: Sendable, Equatable, Identifiable {
        public let id: String
        public let kind: NodeKind
        public let label: String
        public let column: Int
        public let row: Int
        public init(id: String, kind: NodeKind, label: String, column: Int, row: Int) {
            self.id = id; self.kind = kind; self.label = label
            self.column = column; self.row = row
        }
    }

    public struct Edge: Sendable, Equatable {
        public let from: String
        public let to: String
        public init(from: String, to: String) { self.from = from; self.to = to }
    }

    public let nodes: [Node]
    public let edges: [Edge]
    public let source: Source
    public var isEmpty: Bool { nodes.isEmpty }
    public var columns: Int { (nodes.map(\.column).max() ?? -1) + 1 }
    public var rows: Int { (nodes.map(\.row).max() ?? -1) + 1 }

    public init(nodes: [Node], edges: [Edge], source: Source = .fastlane) {
        self.nodes = nodes; self.edges = edges; self.source = source
    }
}

public enum FastlaneFlowBuilder {
    /// Ruby keywords / DSL words that are never fastlane actions.
    private static let skip: Set<String> = [
        "if", "unless", "case", "when", "else", "elsif", "begin", "rescue",
        "ensure", "end", "do", "while", "until", "for", "return", "next",
        "break", "yield", "then", "in", "lane", "private_lane", "platform",
        "desc", "puts", "require", "import", "self", "true", "false", "nil",
    ]
    private static let maxStepsPerLane = 14

    /// A lane plus the ordered action / sub-lane tokens in its body.
    struct ParsedLane { let name: String; let steps: [String] }

    /// Parse each lane body: from `lane :x do` to the `end` at the same
    /// indentation. A step is the leading snake_case identifier of a
    /// statement (fastlane actions are lowercase); assignments, logging
    /// (`UI.…`), comments, and control keywords are skipped.
    static func parseLanes(fromFastfile text: String) -> [ParsedLane] {
        let lines = text.components(separatedBy: "\n")
        var result: [ParsedLane] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = trimmed.firstMatch(of: /^(?:private_)?lane\s+:(\w+)/) {
                let indent = line.prefix { $0 == " " || $0 == "\t" }.count
                var steps: [String] = []
                var j = i + 1
                while j < lines.count {
                    let body = lines[j]
                    let bt = body.trimmingCharacters(in: .whitespaces)
                    let bodyIndent = body.prefix { $0 == " " || $0 == "\t" }.count
                    if bt == "end", bodyIndent == indent { break }
                    if let step = stepToken(bt), steps.count < maxStepsPerLane {
                        steps.append(step)
                    }
                    j += 1
                }
                result.append(ParsedLane(name: String(match.1), steps: steps))
                i = j
            }
            i += 1
        }
        return result
    }

    /// The action/lane token a statement invokes, or nil.
    private static func stepToken(_ line: String) -> String? {
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
        // Assignment (`x = build_app`) or hash/array noise → skip the
        // leading name; we want the invoked action, not the lvalue.
        guard let match = line.firstMatch(of: /^([a-z_][a-z0-9_]*)/) else { return nil }
        let token = String(match.1)
        guard !skip.contains(token) else { return nil }
        // A bare word that's actually a modifier line ("foo if bar") is
        // still the action `foo` — fine. Assignments start "name =":
        if line.firstMatch(of: /^[a-z_][a-z0-9_]*\s*=[^=]/) != nil { return nil }
        return token
    }

    /// Map each CI invocation string ("deploy.yml: … fastlane ios beta")
    /// to the lane it runs, keyed lane → workflow files.
    static func triggers(from invocations: [String],
                         laneNames: Set<String>) -> [String: [String]] {
        var byLane: [String: [String]] = [:]
        for invocation in invocations {
            let parts = invocation.split(separator: " ").map(String.init)
            // The lane is the last token that names a known lane.
            guard let lane = parts.last(where: { laneNames.contains($0) }) else { continue }
            let file = invocation.split(separator: ":").first.map(String.init) ?? "CI"
            byLane[lane, default: []].append(file)
        }
        return byLane.mapValues { Array(Set($0)).sorted() }
    }

    /// Build the laid-out flowchart. One row per lane: trigger (col 0),
    /// lane (col 1), then its steps chained left-to-right; sub-lane
    /// calls wire to the target lane's node.
    public static func build(info: FastlaneInfo, fastfileText: String) -> CIFlow {
        let parsed = parseLanes(fromFastfile: fastfileText)
        let laneNames = Set(parsed.map(\.name))
        let triggersByLane = triggers(from: info.ciInvocations, laneNames: laneNames)

        typealias Node = CIFlow.Node
        typealias Edge = CIFlow.Edge
        var nodes: [Node] = []
        var edges: [Edge] = []
        for (row, lane) in parsed.enumerated() {
            let laneID = "lane:\(lane.name)"
            nodes.append(Node(id: laneID, kind: .lane, label: lane.name, column: 1, row: row))

            for file in triggersByLane[lane.name] ?? [] {
                let triggerID = "trigger:\(lane.name):\(file)"
                nodes.append(Node(id: triggerID, kind: .trigger, label: file, column: 0, row: row))
                edges.append(Edge(from: triggerID, to: laneID))
            }

            var previous = laneID
            for (i, step) in lane.steps.enumerated() {
                let isLaneCall = laneNames.contains(step) && step != lane.name
                let stepID = "\(laneID)#\(i):\(step)"
                nodes.append(Node(id: stepID, kind: isLaneCall ? .laneCall : .action,
                                  label: step, column: 2 + i, row: row))
                edges.append(Edge(from: previous, to: stepID))
                if isLaneCall {
                    edges.append(Edge(from: stepID, to: "lane:\(step)"))
                }
                previous = stepID
            }
        }
        return CIFlow(nodes: nodes, edges: edges, source: .fastlane)
    }
}

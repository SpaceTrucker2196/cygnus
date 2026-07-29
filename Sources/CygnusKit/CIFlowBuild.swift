import Foundation

// Live build state for the CI Flow view. A build runs the pipeline for
// real; its streamed output drives a per-node run state so the Metal
// renderer can light the flow up as work happens.

public enum NodeRunState: String, Sendable, Equatable {
    case pending    // not reached yet
    case active     // running now
    case done       // completed
    case failed     // errored here
}

public struct BuildProgress: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case idle, running, succeeded, failed
    }
    public var phase: Phase = .idle
    public var command: String = ""
    public var nodeStates: [String: NodeRunState] = [:]
    public var activeNodeID: String?
    public var log: [String] = []
    public var lastLine: String { log.last ?? "" }
    public var isRunning: Bool { phase == .running }

    public init() {}

    static let logCap = 400
    mutating func append(_ line: String) {
        log.append(line)
        if log.count > Self.logCap { log.removeFirst(log.count - Self.logCap) }
    }
}

// Maps a stream of build-output lines onto flow-node states. The model
// is a frontier over the flow's step nodes (in row-major order): each
// meaningful command line advances it, aligning to a node whose label
// matches the program the line runs when it can, and completing the
// steps it passed. Group (lane/target) and entry (trigger/goal) states
// are derived from their steps. Heuristic, but paced by real output —
// the animation reflects the build actually progressing.
public struct CIFlowBuildTracker: Sendable {
    private let flow: CIFlow
    private let steps: [CIFlow.Node]          // action/laneCall, row-major
    private let stepsByGroup: [Int: [Int]]    // row -> indices into `steps`
    private let groupIDByRow: [Int: String]   // row -> lane/target node id
    private let entryIDByRow: [Int: String]   // row -> trigger node id
    public private(set) var states: [String: NodeRunState] = [:]
    public private(set) var activeID: String?
    private var frontier = 0                   // next step index to run

    public init(flow: CIFlow) {
        self.flow = flow
        let ordered = flow.nodes
            .filter { $0.kind == .action || $0.kind == .laneCall }
            .sorted { ($0.row, $0.column) < ($1.row, $1.column) }
        self.steps = ordered
        var byGroup: [Int: [Int]] = [:]
        for (i, node) in ordered.enumerated() { byGroup[node.row, default: []].append(i) }
        self.stepsByGroup = byGroup
        var groupID: [Int: String] = [:], entryID: [Int: String] = [:]
        for node in flow.nodes {
            if node.kind == .lane { groupID[node.row] = node.id }
            if node.kind == .trigger { entryID[node.row] = node.id }
        }
        self.groupIDByRow = groupID
        self.entryIDByRow = entryID
    }

    /// All pending; the first group and its entry go active.
    public mutating func start() {
        states = [:]
        for node in flow.nodes { states[node.id] = .pending }
        frontier = 0
        activate(step: 0)
        recomputeGroups()
    }

    /// Advance on a line that looks like a command being executed.
    public mutating func consume(line: String) {
        guard isCommand(line), !steps.isEmpty, frontier < steps.count else { return }
        let prog = program(of: line)
        // Prefer aligning to an upcoming step whose label matches the
        // program; otherwise just step the frontier by one.
        var target = frontier
        if let prog {
            if let hit = (frontier..<steps.count).first(where: {
                steps[$0].label.caseInsensitiveCompare(prog) == .orderedSame
            }) { target = hit }
        }
        // Everything up to `target` is now done; `target` is active.
        for i in frontier..<target { states[steps[i].id] = .done }
        activate(step: target)
        frontier = target + 1
        if frontier <= steps.count - 1 { /* more to go */ }
        recomputeGroups()
    }

    /// Terminal: exit 0 marks everything done; non-zero fails the
    /// active step (and its group) and leaves the rest pending.
    public mutating func finish(exitCode: Int32) {
        if exitCode == 0 {
            for id in states.keys { states[id] = .done }
            activeID = nil
        } else {
            if let active = activeID {
                states[active] = .failed
                if let node = flow.nodes.first(where: { $0.id == active }),
                   let group = groupIDByRow[node.row] { states[group] = .failed }
            }
        }
        recomputeGroups(preserveFailed: true)
    }

    private mutating func activate(step index: Int) {
        guard index >= 0, index < steps.count else { activeID = nil; return }
        // Mark the previously active step done.
        if let active = activeID, states[active] == .active { states[active] = .done }
        states[steps[index].id] = .active
        activeID = steps[index].id
    }

    /// Derive group/entry state from the steps under each row.
    private mutating func recomputeGroups(preserveFailed: Bool = false) {
        for (row, indices) in stepsByGroup {
            let stepStates = indices.map { states[steps[$0].id] ?? .pending }
            let derived: NodeRunState
            if preserveFailed, stepStates.contains(.failed) { derived = .failed }
            else if stepStates.allSatisfy({ $0 == .done }) { derived = .done }
            else if stepStates.contains(where: { $0 == .active || $0 == .done }) { derived = .active }
            else { derived = .pending }
            if let gid = groupIDByRow[row] {
                if !(preserveFailed && states[gid] == .failed) { states[gid] = derived }
            }
            if let eid = entryIDByRow[row] {
                states[eid] = derived == .pending ? .pending : .done
            }
        }
        // Groups with no steps: mirror their entry activation.
        for (row, gid) in groupIDByRow where stepsByGroup[row] == nil {
            if states[gid] == .pending, row == 0 { states[gid] = .active }
        }
    }

    // MARK: Line classification

    private func isCommand(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        // Make's own bookkeeping isn't build work.
        if t.hasPrefix("make[") || t.hasPrefix("make:") || t.hasPrefix("gmake") { return false }
        // A command line runs a program: starts with a path/word and has
        // arguments, or matches a known step label exactly.
        if let prog = program(of: t) {
            if steps.contains(where: { $0.label.caseInsensitiveCompare(prog) == .orderedSame }) {
                return true
            }
        }
        // Fallback: a shell-command-looking line (a word then a space,
        // no leading punctuation, not a diagnostic like "error:").
        return t.first?.isLetter == true && t.contains(" ") && !t.contains(": error")
    }

    private func program(of line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let first = t.split(separator: " ").first else { return nil }
        let word = first.split(separator: "/").last.map(String.init) ?? String(first)
        return word.isEmpty ? nil : word
    }
}

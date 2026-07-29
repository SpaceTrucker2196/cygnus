import Foundation

// A Makefile as a CI flow: each target becomes a group node, its recipe
// lines become the ordered step nodes, and prerequisite targets wire in
// as dependency edges (target → target). The default goal (first real
// target, or `all`) is marked as the entry. Read-only line parsing over
// the Make syntax — never executed.

public enum MakeFlowBuilder {
    /// The recipe program a command line invokes, for a short label
    /// (`clang -c foo.c` → "clang"). Assignments and directives aren't
    /// commands.
    private static let maxRecipePerTarget = 12

    struct ParsedTarget {
        let name: String
        let prerequisites: [String]
        let recipe: [String]       // leading command word of each recipe line
        let isPhony: Bool
    }

    /// Parse `target: prereqs` rules and their tab-indented recipes.
    /// Continuation lines (`\`) are joined; `.PHONY` names are tracked;
    /// pattern rules (`%.o:`) and variable assignments are skipped.
    static func parseTargets(fromMakefile text: String) -> [ParsedTarget] {
        let joined = joinContinuations(text)
        let vars = collectVars(joined)
        var phony: Set<String> = []
        var targets: [ParsedTarget] = []
        var current: (name: String, prereqs: [String], recipe: [String])?

        func flush() {
            if let c = current {
                targets.append(ParsedTarget(
                    name: c.name, prerequisites: c.prereqs,
                    recipe: c.recipe, isPhony: phony.contains(c.name)))
            }
            current = nil
        }

        for rawLine in joined.components(separatedBy: "\n") {
            if rawLine.isEmpty { continue }
            // Recipe lines are tab-indented (make requires a real tab).
            if rawLine.first == "\t" {
                let cmd = rawLine.drop { $0 == "\t" || $0 == " " }
                if let word = recipeCommand(String(cmd), vars: vars), current != nil,
                   current!.recipe.count < maxRecipePerTarget {
                    current!.recipe.append(word)
                }
                continue
            }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix(".PHONY") {
                let names = line.dropFirst(".PHONY".count)
                    .drop { $0 == ":" || $0 == " " }
                phony.formUnion(names.split(separator: " ").map(String.init))
                continue
            }
            // A rule: `targets : prereqs`. Exclude `:=`/`::=`/`?=`/`=`
            // assignments and pattern/suffix rules.
            guard let colon = ruleColon(line) else { continue }
            let lhs = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let rhs = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let names = lhs.split(separator: " ").map(String.init)
            // Keep variable/pattern targets ($(TARGET), %.o) verbatim —
            // they're the backbone of most Makefiles; filtering them
            // would disconnect the graph. Prerequisites are kept as-is
            // too, so a `$(TARGET)` prereq still links to its rule.
            guard let name = names.first else { continue }
            flush()
            let prereqs = rhs.split(separator: " ").map(String.init)
            current = (name, prereqs, [])
        }
        flush()
        return targets
    }

    /// Index of the rule `:` in a line, or nil if the line is an
    /// assignment (`X := …`, `X = …`, `X ?= …`) rather than a rule.
    private static func ruleColon(_ line: String) -> String.Index? {
        guard let colon = line.firstIndex(of: ":") else {
            // No colon → maybe `X = y`; not a rule.
            return nil
        }
        // `:=` / `::=` are assignments, not rules.
        let after = line.index(after: colon)
        if after < line.endIndex, line[after] == "=" { return nil }
        // An `=` before the colon means assignment (`CFLAGS = -O2`).
        if let eq = line.firstIndex(of: "="), eq < colon { return nil }
        return colon
    }

    private static func recipeCommand(_ line: String, vars: [String: String]) -> String? {
        var s = line
        // Strip make's recipe prefixes: @ (silent), - (ignore errors),
        // + (always run).
        while let f = s.first, f == "@" || f == "-" || f == "+" { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        guard let word = s.split(separator: " ").first.map(String.init),
              !word.isEmpty else { return nil }
        // A leading $(VAR) like $(CC): resolve to its assigned value so
        // the label reads "cc" (and matches what make echoes at build
        // time). Unknown vars fall back to the bare variable name.
        if word.hasPrefix("$(") || word.hasPrefix("${") {
            let name = String(word.dropFirst(2).prefix { $0 != ")" && $0 != "}" })
            guard !name.isEmpty else { return nil }
            if let value = vars[name], let first = value.split(separator: " ").first {
                return basename(String(first))
            }
            return name
        }
        // Bare assignment inside a recipe (rare) — skip.
        if word.contains("=") { return nil }
        return basename(word)
    }

    private static func basename(_ word: String) -> String {
        // ./configure → configure; /usr/bin/install → install.
        word.split(separator: "/").last.map(String.init) ?? word
    }

    /// Collect simple variable assignments (`X = y`, `:=`, `?=`, `+=`)
    /// so recipe commands can resolve `$(X)`. First-wins for `?=`,
    /// last-wins for the rest; recipe lines (tab-indented) are ignored.
    static func collectVars(_ joined: String) -> [String: String] {
        var vars: [String: String] = [:]
        for line in joined.components(separatedBy: "\n") {
            if line.first == "\t" { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let match = t.firstMatch(
                of: /^([A-Za-z_][A-Za-z0-9_]*)\s*(\?=|\+=|::=|:=|=)\s*(.*)$/)
            else { continue }
            let name = String(match.1), op = String(match.2)
            let value = String(match.3).trimmingCharacters(in: .whitespaces)
            switch op {
            case "?=": if vars[name] == nil { vars[name] = value }
            case "+=": vars[name] = (vars[name].map { $0 + " " } ?? "") + value
            default:   vars[name] = value
            }
        }
        return vars
    }

    /// Join `\`-continued lines into single logical lines.
    private static func joinContinuations(_ text: String) -> String {
        var out: [String] = []
        var buffer = ""
        for line in text.components(separatedBy: "\n") {
            if line.hasSuffix("\\") {
                buffer += line.dropLast() + " "
            } else {
                out.append(buffer + line)
                buffer = ""
            }
        }
        if !buffer.isEmpty { out.append(buffer) }
        return out.joined(separator: "\n")
    }

    /// Build the laid-out flow. One row per target: the target node
    /// (col 1), then its recipe commands chained right. Prerequisite
    /// targets wire target → target; the default goal gets an entry
    /// node in col 0.
    public static func build(makefileText text: String) -> CIFlow {
        let targets = parseTargets(fromMakefile: text)
        guard !targets.isEmpty else { return CIFlow(nodes: [], edges: [], source: .make) }
        let targetNames = Set(targets.map(\.name))

        // Default goal: `all` if present, else the first target.
        let defaultGoal = targets.first { $0.name == "all" }?.name ?? targets[0].name

        typealias Node = CIFlow.Node
        typealias Edge = CIFlow.Edge
        var nodes: [Node] = []
        var edges: [Edge] = []
        for (row, target) in targets.enumerated() {
            let targetID = "target:\(target.name)"
            nodes.append(Node(id: targetID, kind: .lane, label: target.name, column: 1, row: row))

            if target.name == defaultGoal {
                let entryID = "goal:\(target.name)"
                nodes.append(Node(id: entryID, kind: .trigger,
                                  label: target.isPhony ? "make" : "goal", column: 0, row: row))
                edges.append(Edge(from: entryID, to: targetID))
            }

            // Prerequisite targets feed this target (dependency → target).
            for prereq in target.prerequisites where targetNames.contains(prereq) {
                edges.append(Edge(from: "target:\(prereq)", to: targetID))
            }

            var previous = targetID
            for (i, cmd) in target.recipe.enumerated() {
                let stepID = "\(targetID)#\(i):\(cmd)"
                nodes.append(Node(id: stepID, kind: .action, label: cmd, column: 2 + i, row: row))
                edges.append(Edge(from: previous, to: stepID))
                previous = stepID
            }
        }
        return CIFlow(nodes: nodes, edges: edges, source: .make)
    }
}

import Foundation

// Makefile rule parsing, reduced to what the graph needs: which
// targets exist and what each is declared to depend on. Pure text in,
// facts out — no execution, no variable expansion beyond simple
// assignments, no filesystem.
//
// This is deliberately *less* than the app-side flow parser
// (Sources/CygnusKit/MakeFlow.swift), which also needs recipe command
// words and ordering to draw a flowchart. See docs/wiki/renderers.md.

public struct MakeRule: Sendable, Equatable {
    public let target: String
    /// Prerequisites verbatim, in declaration order.
    public let prerequisites: [String]
    public let isPhony: Bool

    public init(target: String, prerequisites: [String], isPhony: Bool) {
        self.target = target
        self.prerequisites = prerequisites
        self.isPhony = isPhony
    }
}

public enum MakefileRules {
    /// Parse `target: prereqs` rules. Recipe lines are skipped —
    /// prerequisites are where Make states its file dependencies, and
    /// they are what the graph wants.
    public static func parse(_ text: String) -> [MakeRule] {
        let joined = joinContinuations(text)
        let variables = assignments(in: joined)
        var phony: Set<String> = []
        var rules: [MakeRule] = []

        for raw in joined.components(separatedBy: "\n") {
            // A real tab starts a recipe line; Make requires it.
            if raw.first == "\t" { continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix(".PHONY") {
                phony.formUnion(line.dropFirst(".PHONY".count)
                    .drop { $0 == ":" || $0 == " " }
                    .split(separator: " ").map(String.init))
                continue
            }
            guard let colon = ruleColon(line) else { continue }
            let lhs = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let rhs = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            // Expand before splitting: a variable usually holds a
            // *list*, so `$(OBJS)` must become several prerequisites,
            // not one prerequisite named "a.o b.o".
            //
            // Order-only prerequisites (after `|`) are still
            // dependencies; the distinction is about ordering, not
            // about whether the coupling exists.
            let prerequisites = expand(rhs, with: variables)
                .replacingOccurrences(of: "|", with: " ")
                .split(separator: " ").map(String.init)
                .filter { !$0.isEmpty }

            for expanded in expand(lhs, with: variables)
                .split(separator: " ").map(String.init) {
                // Pattern and suffix rules (%.o, .c.o) describe a
                // shape, not a thing — they have no identity to give
                // an entity.
                guard !expanded.isEmpty, !expanded.contains("%"), expanded != ".PHONY"
                else { continue }
                rules.append(MakeRule(target: expanded, prerequisites: prerequisites,
                                      isPhony: phony.contains(expanded)))
            }
        }
        // A target may be stated more than once (rules split across
        // the file); merge rather than emitting a duplicate entity.
        return merge(rules, phony: phony)
    }

    private static func merge(_ rules: [MakeRule], phony: Set<String>) -> [MakeRule] {
        var order: [String] = []
        var byTarget: [String: [String]] = [:]
        for rule in rules {
            if byTarget[rule.target] == nil { order.append(rule.target) }
            var existing = byTarget[rule.target] ?? []
            for prerequisite in rule.prerequisites where !existing.contains(prerequisite) {
                existing.append(prerequisite)
            }
            byTarget[rule.target] = existing
        }
        return order.map {
            MakeRule(target: $0, prerequisites: byTarget[$0] ?? [],
                     isPhony: phony.contains($0))
        }
    }

    /// Index of the rule `:`, or nil when the line is an assignment
    /// (`X := …`, `X ?= …`, `X = …`) rather than a rule.
    static func ruleColon(_ line: String) -> String.Index? {
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "=" { return nil }              // plain assignment
            if character == ":" {
                let next = line.index(after: index)
                if next < line.endIndex, line[next] == "=" { return nil }   // :=
                if next < line.endIndex, line[next] == ":" {
                    let third = line.index(after: next)
                    if third < line.endIndex, line[third] == "=" { return nil }  // ::=
                }
                return index
            }
            if character == "?", line.index(after: index) < line.endIndex,
               line[line.index(after: index)] == "=" { return nil }
            index = line.index(after: index)
        }
        return nil
    }

    /// Simple `NAME = value` assignments, so `$(CC)` resolves to what
    /// make would echo. Recursive expansion is not attempted; an
    /// unresolvable variable stays verbatim rather than becoming a
    /// wrong answer.
    static func assignments(in text: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in text.components(separatedBy: "\n") {
            guard raw.first != "\t" else { continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            var nameEnd = equals
            // Absorb the operator character of :=, ?=, +=
            if nameEnd > line.startIndex {
                let previous = line.index(before: nameEnd)
                if ":?+".contains(line[previous]) { nameEnd = previous }
            }
            let name = String(line[line.startIndex..<nameEnd])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" "), !name.contains(":") else { continue }
            result[name] = String(line[line.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// One level of `$(NAME)` / `${NAME}` substitution. One level, not
    /// a fixpoint: a variable defined in terms of itself must not spin.
    static func expand(_ word: String, with variables: [String: String]) -> String {
        guard word.contains("$") else { return word }
        var result = word
        for (name, value) in variables {
            result = result.replacingOccurrences(of: "$(\(name))", with: value)
            result = result.replacingOccurrences(of: "${\(name)}", with: value)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Join backslash-continued lines so a rule split across lines
    /// parses as one.
    static func joinContinuations(_ text: String) -> String {
        var output: [String] = []
        var pending = ""
        for line in text.components(separatedBy: "\n") {
            if line.hasSuffix("\\") {
                pending += line.dropLast() + " "
            } else {
                output.append(pending + line)
                pending = ""
            }
        }
        if !pending.isEmpty { output.append(pending) }
        return output.joined(separator: "\n")
    }
}

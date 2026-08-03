import Foundation

// Makefile rule parsing, reduced to what the graph needs: which
// targets exist, what each is declared to depend on, and what each
// runs. Pure text in, facts out — no execution, no variable expansion
// beyond simple assignments, no filesystem.

public struct MakeRule: Sendable, Equatable {
    public let target: String
    /// Prerequisites verbatim, in declaration order.
    public let prerequisites: [String]
    /// Recipe command lines in execution order, with make's line
    /// prefixes (`@`, `-`, `+`) stripped. Order is the fact here: a
    /// recipe is a sequence, and a set of commands would not say what
    /// the target does.
    public let recipe: [String]
    public let isPhony: Bool

    public init(target: String, prerequisites: [String],
                recipe: [String] = [], isPhony: Bool) {
        self.target = target
        self.prerequisites = prerequisites
        self.recipe = recipe
        self.isPhony = isPhony
    }
}

public enum MakefileRules {
    /// Recipe lines kept per target. A generated Makefile can attach
    /// hundreds to one rule, and past the first handful they describe
    /// the same step in more detail rather than a different one.
    static let maxRecipeLines = 12

    /// Parse `target: prereqs` rules and their recipes.
    /// Prerequisites are where Make states its file dependencies;
    /// the recipe is what the target actually does, in order.
    public static func parse(_ text: String) -> [MakeRule] {
        let joined = joinContinuations(text)
        let variables = assignments(in: joined)
        var phony: Set<String> = []
        var rules: [MakeRule] = []
        // Indices of the rules the most recent rule line produced. A
        // line naming several targets gives each of them the same
        // recipe, which is what make does.
        var currentRules: [Int] = []

        for raw in joined.components(separatedBy: "\n") {
            // A real tab starts a recipe line; Make requires it.
            if raw.first == "\t" {
                guard !currentRules.isEmpty else { continue }
                let command = raw.drop { $0 == "\t" || $0 == " " }
                    // @ suppresses echo, - ignores errors, + forces
                    // execution under -n. None change what runs.
                    .drop { "@-+".contains($0) }
                    .trimmingCharacters(in: .whitespaces)
                guard !command.isEmpty, !command.hasPrefix("#") else { continue }
                // Expanded like prerequisites are, so `$(CC) -c foo.c`
                // records the compiler make would actually run.
                // Automatic variables ($@, $^) stay verbatim: make
                // computes them per invocation and no reading of the
                // file can know them.
                let expanded = expand(command, with: variables)
                for index in currentRules where rules[index].recipe.count < maxRecipeLines {
                    rules[index] = MakeRule(target: rules[index].target,
                                            prerequisites: rules[index].prerequisites,
                                            recipe: rules[index].recipe + [expanded],
                                            isPhony: rules[index].isPhony)
                }
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix(".PHONY") {
                phony.formUnion(line.dropFirst(".PHONY".count)
                    .drop { $0 == ":" || $0 == " " }
                    .split(separator: " ").map(String.init))
                continue
            }
            currentRules = []
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
                currentRules.append(rules.count)
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
        var prerequisites: [String: [String]] = [:]
        var recipes: [String: [String]] = [:]
        for rule in rules {
            if prerequisites[rule.target] == nil { order.append(rule.target) }
            var existing = prerequisites[rule.target] ?? []
            for prerequisite in rule.prerequisites where !existing.contains(prerequisite) {
                existing.append(prerequisite)
            }
            prerequisites[rule.target] = existing
            // Make allows only one recipe per target; a second is a
            // warning and the last one wins. Keep whichever is
            // non-empty rather than concatenating two alternatives
            // into a sequence that never runs.
            if !rule.recipe.isEmpty { recipes[rule.target] = rule.recipe }
        }
        return order.map {
            MakeRule(target: $0, prerequisites: prerequisites[$0] ?? [],
                     recipe: recipes[$0] ?? [], isPhony: phony.contains($0))
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

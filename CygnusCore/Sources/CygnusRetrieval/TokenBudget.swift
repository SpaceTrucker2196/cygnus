import Foundation

// A budget you emit *into*, not a string you cut afterwards.
//
// The difference matters. Post-hoc truncation chops whatever happened
// to be at the end of a rendered blob, which is how an agent ends up
// with half a citation and no idea anything was withheld. Emitting in
// rank order and stopping before the first block that would cross the
// line means what comes back is always a coherent prefix of the best
// results, and the caller always knows what it didn't get.
//
// Two rules are non-negotiable, and both are about honesty rather than
// size:
//
//   1. A citation is always affordable. If a result's body doesn't
//      fit, the body is elided and the citation still emitted — a
//      result you cannot cite is not a result.
//   2. Truncation is never silent. Every response that withheld
//      anything says so, with counts.

public struct TokenBudget: Sendable {
    public let maxTokens: Int
    private(set) public var spent: Int = 0
    private var lines: [String] = []
    private(set) public var shown = 0

    public init(maxTokens: Int) {
        self.maxTokens = max(maxTokens, Self.floorTokens)
    }

    /// Below this a response cannot carry even one cited result plus a
    /// footer, so asking for less is a caller error we quietly correct
    /// rather than an empty response we hand back.
    public static let floorTokens = 200

    /// Reserved so the truncation footer itself can never be the thing
    /// that doesn't fit.
    public static let footerReserve = 40

    /// Deliberately pessimistic: 3 characters per token rather than the
    /// usual ~4. Identifier-dense source tokenizes harder than prose,
    /// and the two errors are not symmetric — under-counting overruns a
    /// real context window, over-counting costs a result or two.
    public static func estimate(_ text: String) -> Int {
        max(1, Int((Double(text.utf8.count) / 3.0).rounded(.up)))
    }

    private var available: Int { maxTokens - Self.footerReserve - spent }

    /// Emit a block if it fits. Returns false when it doesn't, leaving
    /// the budget untouched so the caller can try a shorter form.
    @discardableResult
    public mutating func admit(_ block: String) -> Bool {
        let cost = Self.estimate(block)
        guard cost <= available else { return false }
        lines.append(block)
        spent += cost
        return true
    }

    /// Emit a block that counts as one shown item. For renderings whose
    /// unit is a whole block (a file line in a repo map) rather than a
    /// citation plus body.
    @discardableResult
    public mutating func admitCounted(_ block: String) -> Bool {
        guard admit(block) else { return false }
        shown += 1
        return true
    }

    /// Emit a result: its citation always, its body only if that fits.
    /// This is the rule that keeps a truncated response useful — the
    /// agent still learns the span exists and can go read it.
    @discardableResult
    public mutating func admitResult(citation: String, body: String?) -> Bool {
        guard admit(citation) else { return false }
        shown += 1
        if let body, !body.isEmpty {
            if !admit(body) {
                lines.append("    [body elided — \(Self.estimate(body)) tokens]")
            }
        }
        return true
    }

    /// Emit regardless of budget. For headers, which are the context
    /// that makes everything else interpretable.
    public mutating func admitAlways(_ block: String) {
        lines.append(block)
        spent += Self.estimate(block)
    }

    /// Close out, stating what was withheld. `total` is the number of
    /// results that existed, not the number rendered.
    public consuming func finish(total: Int, nextOffset: Int? = nil) -> String {
        if shown < total {
            var footer = "— shown \(shown) of \(total) (truncated)."
            if let nextOffset { footer += " next: offset=\(nextOffset)" }
            lines.append(footer)
        }
        return lines.joined(separator: "\n")
    }
}

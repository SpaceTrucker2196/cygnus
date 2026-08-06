import Testing
@testable import CygnusRetrieval

// The budget is the contract every tool response is held to. These
// pin the two properties that make a truncated answer trustworthy:
// a result always keeps its citation, and truncation is never silent.

@Suite struct TokenBudgetTests {
    @Test func emissionStopsBeforeCrossingTheLimit() {
        var budget = TokenBudget(maxTokens: 300)
        let block = String(repeating: "x", count: 300)   // ~100 tokens
        var admitted = 0
        while budget.admit(block) { admitted += 1 }
        #expect(admitted > 0)
        // Never exceeds, counting the reserved footer room.
        #expect(budget.spent <= 300 - TokenBudget.footerReserve)
    }

    /// A result you cannot cite is not a result: when the body doesn't
    /// fit, the citation still goes out and the elision is stated.
    @Test func anOversizedBodyIsElidedButItsCitationSurvives() {
        var budget = TokenBudget(maxTokens: 250)
        let admitted = budget.admitResult(
            citation: "repo/file.swift:1-2",
            body: String(repeating: "y", count: 5000))
        #expect(admitted)
        let output = budget.finish(total: 1)
        #expect(output.contains("repo/file.swift:1-2"))
        #expect(output.contains("body elided"))
    }

    @Test func truncationIsAnnouncedWithCounts() {
        var budget = TokenBudget(maxTokens: 250)
        _ = budget.admitCounted("one")
        let output = budget.finish(total: 17)
        #expect(output.contains("shown 1 of 17"))
        #expect(output.contains("truncated"))
    }

    /// Nothing withheld, nothing said — a footer on a complete answer
    /// would just be noise the model has to interpret.
    @Test func aCompleteAnswerCarriesNoFooter() {
        var budget = TokenBudget(maxTokens: 500)
        _ = budget.admitCounted("one")
        _ = budget.admitCounted("two")
        let output = budget.finish(total: 2)
        #expect(!output.contains("truncated"))
    }

    /// Deliberately pessimistic — under-counting overruns a real
    /// context window, over-counting costs a result.
    @Test func theEstimateErrsHigh() {
        // ~12 chars of ASCII is ~3 tokens by the usual 4:1 rule; we
        // must not report fewer than that.
        #expect(TokenBudget.estimate("hello world!") >= 3)
        #expect(TokenBudget.estimate("") == 1)
    }

    @Test func absurdlySmallBudgetsAreRaisedToTheFloor() {
        let budget = TokenBudget(maxTokens: 1)
        #expect(budget.maxTokens == TokenBudget.floorTokens)
    }
}

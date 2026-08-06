import Testing
import Foundation
@testable import CygnusRetrieval

// Parsing the factory's memory. The bias throughout is toward
// surfacing too much rather than too little: an irrelevant past
// decision costs a line of output, a missed one costs rebuilding
// something that was already measured and rejected.

@Suite struct DecisionRecordTests {
    private let sample = """
        # repo — decisions and refusals

        | id | date | decision | status | evidence | supersedes |
        |----|------|----------|--------|----------|------------|
        | D1 | 2026-07-31 | Dead-code detection | refused | measured on cygnus | — |
        | D2 | 2026-08-01 | GRDB for storage | adopted | docs/schema.md | — |
        | D3 | 2026-08-02 | Old approach | superseded | none | D2 |

        ## D1 — dead-code detection, refused

        **Why it fails.** A majority of results were false positives.

        ## D2 — GRDB, adopted

        Interval-versioned, one database per workspace.
        """

    @Test func rowsAndStatusesParse() {
        let records = DecisionReader.parse(sample, repositoryName: "repo")
        #expect(records.count == 3)
        #expect(records[0].id == "D1")
        #expect(records[0].status == .refused)
        #expect(records[1].status == .adopted)
        #expect(records[2].status == .superseded)
    }

    /// The id joins the table row to its reasoning; without that the
    /// record is a headline with no substance behind it.
    @Test func sectionsAttachToTheirRowByID() {
        let records = DecisionReader.parse(sample, repositoryName: "repo")
        let refusal = try! #require(records.first { $0.id == "D1" })
        #expect(refusal.detail?.contains("false positives") == true)
    }

    @Test func supersedesIsCarriedAndEmDashMeansNone() {
        let records = DecisionReader.parse(sample, repositoryName: "repo")
        #expect(records.first { $0.id == "D3" }?.supersedes == "D2")
        #expect(records.first { $0.id == "D1" }?.supersedes == nil)
    }

    /// The template ships an example row; a freshly installed factory
    /// must not look like it already decided something.
    @Test func theTemplatesExampleRowIsIgnored() {
        let template = """
            | id | date | decision | status | evidence | supersedes |
            |----|------|----------|--------|----------|------------|
            | D0 | 2026-01-01 | *(example — delete on first run)* | adopted | none | — |
            """
        #expect(DecisionReader.parse(template, repositoryName: "repo").isEmpty)
    }

    @Test func headerAndSeparatorRowsAreNotDecisions() {
        let records = DecisionReader.parse(sample, repositoryName: "repo")
        #expect(!records.contains { $0.id.lowercased() == "id" })
        #expect(!records.contains { $0.id.contains("-") })
    }

    /// A half-filled record is still worth surfacing — refusing to
    /// parse it would hide exactly the entry someone left unfinished.
    @Test func aRowMissingItsTrailingColumnsStillParses() {
        let partial = """
            | id | date | decision | status | evidence |
            |----|------|----------|--------|----------|
            | D9 | 2026-08-06 | Something | provisional | none |
            """
        let records = DecisionReader.parse(partial, repositoryName: "repo")
        #expect(records.count == 1)
        #expect(records[0].status == .provisional)
        #expect(records[0].supersedes == nil)
    }

    @Test func anUnrecognisedStatusIsUnknownRatherThanADecodeFailure() {
        let odd = """
            | id | date | decision | status | evidence | supersedes |
            |----|------|----------|--------|----------|------------|
            | D1 | 2026-08-06 | Something | maybe? | none | — |
            """
        #expect(DecisionReader.parse(odd, repositoryName: "repo").first?.status == .unknown)
    }
}

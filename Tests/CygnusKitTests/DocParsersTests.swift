import Testing
import Foundation
@testable import CygnusKit

// Pure parsers against real sloth-shaped samples.

@Suite struct DocParsersTests {
    @Test func parsesMetricsTableWithRightAlignedSeparator() {
        let source = """
        # Factory metrics

        | issue | commit | date | converge_iters | tests_at_ship | shipped | notes |
        |------:|--------|------|---------------:|--------------:|:-------:|-------|
        | 34 | 8714467 | 2026-07-05 | 1 | 3572 | yes | docs only, green first converge |
        | 35 | 7d21d42 | 2026-07-14 | 2 | 3672 | no | rode #17 machinery |
        """
        let rows = FactoryParse.metricsRows(source)
        #expect(rows.count == 2)
        #expect(rows[0].issue == 34)
        #expect(rows[0].commit == "8714467")
        #expect(rows[0].convergeIters == 1)
        #expect(rows[0].testsAtShip == 3572)
        #expect(rows[0].shipped == true)
        #expect(rows[1].shipped == false)
        #expect(rows[0].notes.contains("green first converge"))
    }

    @Test func parsesLedgerTable() {
        let source = """
        | commit | date | model(s) | input | output | cache_read | cache_write | cost_usd | summary |
        |--------|------|----------|------:|-------:|-----------:|------------:|---------:|---------|
        | 5ca63d2 | 2026-06-10T15:42:15Z | claude-opus-4-7 | 123 | 38012 | 9244812 | 226191 | 7.8352 | Passive observers |
        """
        let rows = FactoryParse.ledgerRows(source)
        #expect(rows.count == 1)
        #expect(rows[0].commit == "5ca63d2")
        #expect(rows[0].model == "claude-opus-4-7")
        #expect(rows[0].output == 38012)
        #expect(rows[0].costUSD == 7.8352)
        #expect(rows[0].summary == "Passive observers")
    }

    @Test func toleratesMissingCells() {
        let source = """
        | issue | commit | date | converge_iters | tests_at_ship | shipped | notes |
        |------:|--------|------|---------------:|--------------:|:-------:|-------|
        |  | abcdef1 |  |  |  |  |  |
        """
        let rows = FactoryParse.metricsRows(source)
        #expect(rows.count == 1)
        #expect(rows[0].issue == nil)
        #expect(rows[0].commit == "abcdef1")
        #expect(rows[0].date == nil)
        #expect(rows[0].shipped == nil)
    }

    @Test func parsesConvergeSteps() {
        let source = """
        # Converge

        1. **Read the order.** `gh issue view $ARGUMENTS` — parse goal,
           acceptance criteria, test requirements.
        2. **Plan.** Map the change against agents/AGENTS.md.
        3. **Generate.** Implement per the repo recipes.
        """
        let steps = FactoryParse.convergeSteps(source)
        #expect(steps.count == 3)
        #expect(steps[0].index == 1)
        #expect(steps[0].title == "Read the order")
        #expect(steps[0].detail.contains("parse goal"))       // continuation joined
        #expect(steps[1].title == "Plan")
    }

    @Test func parsesClosesRefsCaseInsensitive() {
        #expect(FactoryParse.closedIssues(in: "Fix thing (closes #45)") == [45])
        #expect(FactoryParse.closedIssues(in: "resolves #12 and Fixes #34") == [12, 34])
        #expect(FactoryParse.closedIssues(in: "no refs here").isEmpty)
    }

    @Test func recognisesLedgerAndMetricsCommits() {
        #expect(FactoryParse.isLedgerOrMetricsCommit("chore(ledger): a688b25"))
        #expect(FactoryParse.isLedgerOrMetricsCommit("chore(metrics): #45 converge row"))
        #expect(!FactoryParse.isLedgerOrMetricsCommit("Add feature (closes #1)"))
    }

    @Test func parsesGitLogLine() {
        let line = "a688b25full\u{0}a688b25\u{0}Jeff Kunzelman\u{0}2026-07-20T06:45:06-07:00\u{0}Add gate (closes #45)"
        let commit = FactoryParse.commit(fromLogLine: line)
        #expect(commit?.shortSha == "a688b25")
        #expect(commit?.author == "Jeff Kunzelman")
        #expect(commit?.closesIssues == [45])
        #expect(commit?.ledgerMarker == false)
    }

    @Test func parsesRemoteFromBothURLForms() {
        #expect(RepoRemote.parse(originURL: "https://github.com/SpaceTrucker2196/sloth.git")?.slug
                == "SpaceTrucker2196/sloth")
        #expect(RepoRemote.parse(originURL: "git@github.com:SpaceTrucker2196/sloth.git")?.slug
                == "SpaceTrucker2196/sloth")
        #expect(RepoRemote.parse(originURL: "https://gitlab.com/x/y.git") == nil)
    }
}

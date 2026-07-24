import Foundation

// Pure parsers for the local factory files: METRICS.md / LEDGER.md
// pipe tables, the converge-loop step list, and git-log commit
// markers. No I/O — all take strings and return values, so they're
// trivially testable against real sloth samples.

public enum FactoryParse {

    // MARK: - Dates

    /// Lenient date parsing across the formats these files use: bare
    /// `YYYY-MM-DD` (METRICS), ISO-8601 with Z or offset (LEDGER, git).
    /// Formatters are built per call — Foundation's are not Sendable and
    /// these parse volumes are small.
    public static func date(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: trimmed) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: trimmed) { return d }

        let dayOnly = DateFormatter()
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.timeZone = TimeZone(identifier: "UTC")
        dayOnly.dateFormat = "yyyy-MM-dd"
        return dayOnly.date(from: trimmed)
    }

    // MARK: - Markdown pipe tables

    /// Split a GitHub-flavoured markdown table into rows of trimmed
    /// cells, dropping the header and the `|---|` separator. Tolerates
    /// leading/trailing pipes and right-aligned (`---:`) separators.
    static func tableRows(_ source: String) -> [[String]] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }
        var rows: [[String]] = []
        var seenSeparator = false
        for line in lines {
            if isSeparatorRow(line) { seenSeparator = true; continue }
            let cells = splitCells(line)
            // The first pipe line before the separator is the header.
            if !seenSeparator && rows.isEmpty { continue }
            if seenSeparator { rows.append(cells) }
        }
        return rows
    }

    private static func isSeparatorRow(_ line: String) -> Bool {
        let inner = line.trimmingCharacters(in: CharacterSet(charactersIn: "| \t"))
        guard !inner.isEmpty else { return false }
        return inner.allSatisfy { $0 == "-" || $0 == ":" || $0 == "|" || $0 == " " }
    }

    private static func splitCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func int(_ cell: String) -> Int? {
        Int(cell.trimmingCharacters(in: .whitespaces))
    }
    private static func double(_ cell: String) -> Double? {
        Double(cell.trimmingCharacters(in: .whitespaces))
    }
    private static func bool(_ cell: String) -> Bool? {
        switch cell.lowercased().trimmingCharacters(in: .whitespaces) {
        case "yes", "true", "✓", "y": true
        case "no", "false", "✗", "n": false
        default: nil
        }
    }
    private static func optional(_ cell: String) -> String? {
        let t = cell.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t == "—" || t == "-" ? nil : t
    }

    // MARK: - METRICS.md

    /// Columns: issue | commit | date | converge_iters | tests_at_ship | shipped | notes
    public static func metricsRows(_ source: String) -> [MetricsRow] {
        tableRows(source).compactMap { cells in
            guard cells.count >= 2, let commit = optional(cells[1]) else { return nil }
            return MetricsRow(
                issue: int(cells[0]),
                commit: commit,
                date: cells.count > 2 ? date(cells[2]) : nil,
                convergeIters: cells.count > 3 ? int(cells[3]) : nil,
                testsAtShip: cells.count > 4 ? int(cells[4]) : nil,
                shipped: cells.count > 5 ? bool(cells[5]) : nil,
                notes: cells.count > 6 ? cells[6] : "")
        }
    }

    // MARK: - LEDGER.md

    /// Columns: commit | date | model | input | output | cache_read | cache_write | cost_usd | summary
    public static func ledgerRows(_ source: String) -> [LedgerRow] {
        tableRows(source).compactMap { cells in
            guard cells.count >= 2, let commit = optional(cells[0]) else { return nil }
            // Summary is the last column; token/cost columns sit between
            // date and summary. Read positionally, tolerating short rows.
            func cell(_ i: Int) -> String { i < cells.count ? cells[i] : "" }
            return LedgerRow(
                commit: commit,
                date: date(cell(1)),
                model: cell(2),
                input: int(cell(3)),
                output: int(cell(4)),
                cacheRead: int(cell(5)),
                cacheWrite: int(cell(6)),
                costUSD: double(cell(7)),
                summary: cells.count > 8 ? cells[8...].joined(separator: " | ") : cell(8))
        }
    }

    // MARK: - converge.md

    /// Steps look like: `N. **Title.** detail…` with detail possibly
    /// continuing on wrapped lines until the next numbered item.
    public static func convergeSteps(_ source: String) -> [ConvergeStep] {
        var steps: [(index: Int, title: String, detail: [String])] = []
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let (index, title, rest) = numberedBoldHeader(line) {
                steps.append((index, title, rest.isEmpty ? [] : [rest]))
            } else if !line.isEmpty, !steps.isEmpty {
                // Continuation of the current step's detail.
                steps[steps.count - 1].detail.append(line)
            } else if line.isEmpty {
                continue
            }
        }
        return steps.map { step in
            ConvergeStep(index: step.index, title: step.title,
                         detail: step.detail.joined(separator: " ")
                            .trimmingCharacters(in: .whitespaces))
        }
    }

    /// Match `N. **Title.**  rest` → (N, "Title", "rest"). Title has its
    /// trailing period stripped.
    private static func numberedBoldHeader(_ line: String) -> (Int, String, String)? {
        guard let dot = line.firstIndex(of: "."),
              let index = Int(line[line.startIndex..<dot]) else { return nil }
        let afterNumber = line[line.index(after: dot)...].drop(while: { $0 == " " })
        guard afterNumber.hasPrefix("**") else { return nil }
        let afterOpen = afterNumber.dropFirst(2)
        guard let closeRange = afterOpen.range(of: "**") else { return nil }
        var title = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])
        if title.hasSuffix(".") { title.removeLast() }
        let rest = String(afterOpen[closeRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (index, title, rest)
    }

    // MARK: - Commit subjects

    /// Parse `(closes #N)`, `(fixes #N)`, `(resolves #N)` (any case) →
    /// [N]. Multiple refs allowed.
    public static func closedIssues(in subject: String) -> [Int] {
        let pattern = #"(?i)\b(?:closes|fixes|resolves)\s+#(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(subject.startIndex..., in: subject)
        return regex.matches(in: subject, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: subject) else { return nil }
            return Int(subject[r])
        }
    }

    public static func isLedgerOrMetricsCommit(_ subject: String) -> Bool {
        let lowered = subject.lowercased()
        return lowered.hasPrefix("chore(ledger") || lowered.hasPrefix("chore(metrics")
    }

    /// Parse one git-log line formatted `%H\0%h\0%an\0%aI\0%s`.
    public static func commit(fromLogLine line: String) -> CommitInfo? {
        let fields = line.components(separatedBy: "\u{0}")
        guard fields.count >= 5 else { return nil }
        let subject = fields[4]
        return CommitInfo(
            sha: fields[0], shortSha: fields[1], subject: subject,
            author: fields[2], date: date(fields[3]) ?? Date(timeIntervalSince1970: 0),
            closesIssues: closedIssues(in: subject),
            ledgerMarker: isLedgerOrMetricsCommit(subject))
    }
}

import Foundation

// Authorship history, reported without interpretation: who touched
// which file, when. Who *owns* something is a judgement made later,
// from these facts.
//
// Parsing is a pure function over `git log` output so it tests without
// a repository.

public struct GitCommit: Sendable, Equatable {
    public let sha: String
    public let authorName: String
    public let authorEmail: String
    public let date: Date
    /// Repo-relative paths this commit touched.
    public let paths: [String]

    public init(sha: String, authorName: String, authorEmail: String,
                date: Date, paths: [String]) {
        self.sha = sha
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.date = date
        self.paths = paths
    }
}

public enum GitHistory {
    /// Record and field separators — ASCII control characters, so a
    /// commit subject or a path containing newlines cannot corrupt the
    /// parse.
    static let recordSeparator = "\u{1e}"
    static let fieldSeparator = "\u{1f}"

    /// How much history is read by default. Authorship is the first
    /// history-sized data the graph holds, and a repository with
    /// 100,000 commits would otherwise dwarf everything else in it.
    /// Recent history is also the more honest signal — who touched
    /// this lately says more about ownership than who touched it in
    /// 2014.
    public static let defaultCommitLimit = 2_000

    /// Read authorship history. Returns an empty array when git is
    /// unavailable or this is not a repository — absence of git is not
    /// an error.
    public static func commits(of root: URL,
                               limit: Int = defaultCommitLimit) -> [GitCommit] {
        guard GitInfo.isRepository(root) else { return [] }
        let format = "--format=\(recordSeparator)%H\(fieldSeparator)%an" +
            "\(fieldSeparator)%ae\(fieldSeparator)%aI"
        // Merges are excluded: a merge commit touches files its author
        // never wrote, and attributing them would make whoever merges
        // look like the owner of everything.
        guard let output = run(["git", "-C", root.path, "log",
                                "-n", String(limit), "--no-merges",
                                "--name-only", format], in: root)
        else { return [] }
        return parse(output)
    }

    /// Parse `git log --name-only` output in the format above.
    public static func parse(_ text: String) -> [GitCommit] {
        let formatter = ISO8601DateFormatter()
        var commits: [GitCommit] = []
        for record in text.components(separatedBy: recordSeparator) {
            let lines = record.components(separatedBy: "\n")
            guard let header = lines.first, !header.isEmpty else { continue }
            let fields = header.components(separatedBy: fieldSeparator)
            guard fields.count >= 4 else { continue }
            let paths = lines.dropFirst()
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            commits.append(GitCommit(
                sha: fields[0], authorName: fields[1], authorEmail: fields[2],
                date: formatter.date(from: fields[3]) ?? .distantPast,
                paths: paths))
        }
        return commits
    }

    /// Identity for an author. Email, lowercased — the same person
    /// commits under "Jeff" and "jeff kunzelman", but the address is
    /// stable. Falls back to the name when there is no address.
    public static func identity(email: String, name: String) -> String {
        let trimmed = email.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? name.trimmingCharacters(in: .whitespaces) : trimmed
    }

    private static func run(_ arguments: [String], in root: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read BEFORE waiting. `git log` over a large repository emits
        // far more than a pipe buffer holds, and waiting first
        // deadlocks: the child blocks writing, the parent blocks
        // waiting. This is the same hazard the build-output streaming
        // was written around.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

import Foundation

// Installs the dark-factory skeleton (DF_Template) into a repository.
// Copy-only and additive: files that already exist in the target are
// never touched, so installing into a partial factory fills the gaps
// and installing twice is a no-op. `{{REPO_NAME}}` placeholders are
// substituted on the way in; everything else is verbatim template.

public struct FactoryInstaller: Sendable {
    public struct Result: Sendable, Equatable {
        public let installed: [String]     // repo-relative paths written
        public let skipped: [String]       // already existed, untouched
    }

    public enum InstallerError: Error, Equatable {
        case templateMissing(String)
    }

    public let templateURL: URL

    /// Default template lives beside the other repos. The template is
    /// the canonical source — nothing is embedded in the app, so
    /// editing DF_Template changes what installs.
    public init(templateURL: URL? = nil) {
        self.templateURL = templateURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("projects/DF_Template")
    }

    /// Template files that install into a repo. README.md describes
    /// the template itself and stays behind; git internals never copy.
    static let installedPaths: [String] = [
        "FIRST_RUN.md", "MISSION.md", "CLAUDE.md", "AGENTS.md",
        "FACTORY.md", "LEDGER.md", "METRICS.md", "DECISIONS.md", "PROGRESS.md",
        "SECURITY.md", "ROADMAP.md", "Makefile",
        "wiki/README.md", ".github/workflows/pages.yml",
        "docs/dark-factory.md", "docs/converge.md",
        ".claude/commands/converge.md",
    ]

    public func install(into repoURL: URL) throws -> Result {
        let fm = FileManager.default
        guard fm.fileExists(atPath: templateURL.path) else {
            throw InstallerError.templateMissing(templateURL.path)
        }
        let repoName = repoURL.lastPathComponent
        var installed: [String] = []
        var skipped: [String] = []

        for path in Self.installedPaths {
            let source = templateURL.appendingPathComponent(path)
            let destination = repoURL.appendingPathComponent(path)
            guard fm.fileExists(atPath: source.path) else {
                throw InstallerError.templateMissing(source.path)
            }
            guard !fm.fileExists(atPath: destination.path) else {
                skipped.append(path)
                continue
            }
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            let content = try String(contentsOf: source, encoding: .utf8)
                .replacingOccurrences(of: "{{REPO_NAME}}", with: repoName)
            try content.write(to: destination, atomically: true, encoding: .utf8)
            installed.append(path)
        }
        return Result(installed: installed, skipped: skipped)
    }
}

import Foundation

// Resolving absolute tool paths is load-bearing. A Finder-launched,
// non-sandboxed app inherits only /usr/bin:/bin:/usr/sbin:/sbin — so
// `git` (at /usr/bin/git) is found by PATH but `gh` (at
// /opt/homebrew/bin/gh under Homebrew) is NOT. We never trust $PATH:
// resolve each tool from an explicit override, then a candidate list,
// then a login-shell probe as a last resort.

/// User-supplied absolute paths, e.g. from Settings. `nil` means "let
/// the locator discover it".
public struct ToolOverrides: Codable, Sendable, Equatable {
    public var gitPath: String?
    public var ghPath: String?
    public init(gitPath: String? = nil, ghPath: String? = nil) {
        self.gitPath = gitPath
        self.ghPath = ghPath
    }
}

/// Absolute paths for the tools, resolved once. `ghPath == nil` means
/// GitHub features are unavailable (binary not installed); views gate
/// on that.
public struct ToolLocator: Sendable, Equatable {
    public let gitPath: String?
    public let ghPath: String?

    public init(gitPath: String?, ghPath: String?) {
        self.gitPath = gitPath
        self.ghPath = ghPath
    }

    public func path(for tool: FactoryTool) -> String? {
        switch tool {
        case .git: gitPath
        case .gh: ghPath
        }
    }

    /// Directories to prepend to a child's PATH so that `gh`'s own
    /// `git` subprocess (and anything else it shells to) resolves.
    public var searchDirectories: [String] {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for path in [gitPath, ghPath] {
            if let dir = path.map({ ($0 as NSString).deletingLastPathComponent }),
               !dir.isEmpty, !dirs.contains(dir) {
                dirs.insert(dir, at: 0)
            }
        }
        return dirs
    }

    // MARK: - Resolution

    static let gitCandidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
    static let ghCandidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    /// Resolve both tools. Override → candidate list → login-shell
    /// probe. Pure enough to unit-test by injecting `fileExists` and
    /// `shellProbe`.
    public static func resolve(overrides: ToolOverrides = ToolOverrides(),
                               fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                               shellProbe: (String) -> String? = ToolLocator.loginShellProbe) -> ToolLocator {
        ToolLocator(
            gitPath: resolveOne("git", override: overrides.gitPath,
                                candidates: gitCandidates, fileExists: fileExists, shellProbe: shellProbe),
            ghPath: resolveOne("gh", override: overrides.ghPath,
                               candidates: ghCandidates, fileExists: fileExists, shellProbe: shellProbe))
    }

    static func resolveOne(_ name: String, override: String?, candidates: [String],
                           fileExists: (String) -> Bool, shellProbe: (String) -> String?) -> String? {
        if let override, fileExists(override) { return override }
        for candidate in candidates where fileExists(candidate) { return candidate }
        if let probed = shellProbe(name), fileExists(probed) { return probed }
        return nil
    }

    /// Last resort: ask a login shell where the tool is. Runs
    /// `/bin/zsh -lc 'command -v <name>'`. Best-effort; returns nil on
    /// any failure.
    public static func loginShellProbe(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }
}

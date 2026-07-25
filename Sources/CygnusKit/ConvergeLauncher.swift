import Foundation

// Hands a production order off to the converge loop. Deliberately a
// HANDOFF, not autonomous execution: the app writes a launch script
// and opens it in Terminal, where the loop runs under the user's eye
// in their own environment. The GUI never drives an agent that
// commits or pushes on its own.

public struct ConvergeLauncher: Sendable {
    /// Where the launch scripts live (temp by default).
    public let scriptDirectory: URL

    public init(scriptDirectory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("cygnus-converge")) {
        self.scriptDirectory = scriptDirectory
    }

    /// The shell script Terminal will run: cd into the repo and start
    /// the converge command for the issue. Pure — tests assert its
    /// contents without launching anything.
    public static func script(repoPath: String, issue: Int,
                              command: String = "claude") -> String {
        // Single-quote the path safely (' → '\'').
        let quoted = "'" + repoPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/zsh
        # Cygnus converge launch — review before it acts; you are in the loop.
        cd \(quoted) || exit 1
        echo "Converge order #\(issue) in $(pwd)"
        exec \(command) "/converge \(issue)"
        """
    }

    /// Write the executable `.command` launch script and return its
    /// URL. The App layer opens it (Terminal registers for `.command`,
    /// so a plain `open` needs no AppleScript automation permission);
    /// keeping the open out of the kit keeps the kit AppKit-free.
    @discardableResult
    public func writeScript(repoPath: String, issue: Int) throws -> URL {
        try FileManager.default.createDirectory(
            at: scriptDirectory, withIntermediateDirectories: true)
        let url = scriptDirectory.appendingPathComponent("converge-\(issue).command")
        try Self.script(repoPath: repoPath, issue: issue)
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

extension WorkspaceStore {
    /// The converge launch script for an order, written and ready to
    /// open. Nil if the repo folder can't be resolved.
    public func convergeScript(issue: Int, for id: UUID,
                               launcher: ConvergeLauncher = ConvergeLauncher()) -> URL? {
        guard let root = repoURL(id) else { return nil }
        return try? launcher.writeScript(repoPath: root.path, issue: issue)
    }
}

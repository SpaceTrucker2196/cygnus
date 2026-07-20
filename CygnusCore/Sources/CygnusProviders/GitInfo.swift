import Foundation

// Git facts, reported without interpretation. Used for the snapshot's
// source_ref and (later) rename hints. Absence of git is not an
// error — the LocalFS walk is always authoritative.

public enum GitInfo {
    public static func isRepository(_ root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
    }

    /// HEAD commit hash, or nil when not a git repo / git unavailable.
    public static func headCommit(of root: URL) -> String? {
        guard isRepository(root) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path, "rev-parse", "HEAD"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}

import Foundation

// Source text for the inspector's code pane. Loaded on demand per
// selection, size-capped — the inspector previews code, it is not an
// editor, and a generated multi-megabyte file must not dent the
// memory budget.

public struct SourcePreview: Sendable, Equatable {
    public let path: String
    public let lines: [String]
    /// True when the file was longer than the cap and got cut.
    public let truncated: Bool

    public init(path: String, lines: [String], truncated: Bool) {
        self.path = path
        self.lines = lines
        self.truncated = truncated
    }
}

extension WorkspaceStore {
    /// Byte cap on loaded source (beyond it, the preview truncates).
    public static let sourcePreviewByteCap = 512 * 1024

    /// Read one repo-relative source file for preview. Returns nil for
    /// unreadable/undecodable/empty files.
    public func loadSource(path: String, for id: UUID) async -> SourcePreview? {
        guard let root = repoURL(id) else { return nil }
        let cap = Self.sourcePreviewByteCap
        return try? await RepoAccess.withAccess(to: root) { root in
            let url = root.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
            let truncated = data.count > cap
            let text = String(decoding: data.prefix(cap), as: UTF8.self)
            return SourcePreview(
                path: path,
                lines: text.components(separatedBy: "\n"),
                truncated: truncated)
        }
    }
}

import Foundation

// Security-scoped bookmark handling for user-chosen repo folders.
// Never call startAccessingSecurityScopedResource bare — go through
// withAccess so start/stop always balance (AGENTS.md).

public enum RepoAccessError: Error {
    case staleBookmark
    case unresolvable
}

public enum RepoAccess {
    public static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope,
                             includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public static func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmark,
                          options: .withSecurityScope,
                          relativeTo: nil, bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }

    /// Run `body` with security-scoped access active for the whole
    /// duration — including engine analysis, which reads the tree.
    public static func withAccess<T: Sendable>(to url: URL,
                                               _ body: @Sendable (URL) async throws -> T) async throws -> T {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        return try await body(url)
    }
}

import Foundation

// The app's registry of repositories the user has added: versioned
// Codable JSON, deliberately not a database — one small array,
// inspectable and trivially migratable. Graph data belongs to the
// engine; this file stores only registration + bookmarks.

public struct RegisteredRepo: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public var pathHint: String
    public var bookmark: Data

    public init(id: UUID = UUID(), displayName: String, pathHint: String, bookmark: Data) {
        self.id = id
        self.displayName = displayName
        self.pathHint = pathHint
        self.bookmark = bookmark
    }
}

public struct WorkspacePersistence: Sendable {
    private struct FileFormat: Codable {
        var version: Int
        var repos: [RegisteredRepo]
    }

    public let fileURL: URL

    /// Default location inside the app container.
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Cygnus/workspace.json")
    }

    public func load() -> [RegisteredRepo] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(FileFormat.self, from: data)
        else { return [] }
        return decoded.repos
    }

    public func save(_ repos: [RegisteredRepo]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(FileFormat(version: 1, repos: repos))
            .write(to: fileURL, options: .atomic)
    }
}

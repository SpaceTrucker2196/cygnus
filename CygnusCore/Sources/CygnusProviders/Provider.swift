import Foundation
import CygnusGraph

// Providers expose observable facts about repositories. They never
// interpret semantics — a git provider reports commits and renames;
// it does not decide what an architectural boundary is.

/// A file in an immutable repository snapshot.
public struct SnapshotFile: Hashable, Codable, Sendable {
    public let path: String
    public let blob: BlobHash
    public let size: Int64
    /// Provider's language hint from extension/shebang; extractors
    /// make their own claim decisions.
    public let languageHint: String?
    public init(path: String, blob: BlobHash, size: Int64, languageHint: String?) {
        self.path = path
        self.blob = blob
        self.size = size
        self.languageHint = languageHint
    }
}

/// Well-known project-root markers used by discovery. Markers
/// establish analysis entry points; they do not define architecture.
public enum DiscoveryMarkers {
    public static let all: [String] = [
        ".git", "Package.swift", "package.json", "Cargo.toml", "go.mod",
        "pom.xml", "build.gradle", "CMakeLists.txt", "pyproject.toml",
        "setup.py", "Makefile",
    ]
}

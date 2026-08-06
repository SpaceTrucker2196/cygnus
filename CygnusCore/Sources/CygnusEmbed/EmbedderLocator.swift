import Foundation

// Where the model lives, and what happens when it doesn't.
//
// The weights are a third-party artifact of a few hundred megabytes.
// They are not committed: this is a public repository, git handles
// large binaries badly, and `Package.resolved` cannot pin them the way
// it pins code. So they are converted by `tools/convert-embedder.py`
// and located at runtime.
//
// The consequence has to be stated rather than discovered: **semantic
// search does not work out of the box.** Absent a model, this returns
// nil and the whole tier reports `unavailable` — exactly the contract
// IndexStoreDB enrichment already uses, where a repository without a
// compiled index degrades instead of failing. Every other tier keeps
// working.

public struct EmbedderDescriptor: Sendable, Codable {
    public let name: String
    public let dimension: Int
    public let maxTokens: Int
    /// Prepended to documents and queries respectively. Model families
    /// disagree about this (`e5` wants "query:"/"passage:", `bge` wants
    /// an instruction, MiniLM wants neither) and embedding a query with
    /// the document's prefix measurably degrades recall — so it is data
    /// shipped beside the weights, not a constant in code.
    public let queryPrefix: String
    public let documentPrefix: String
    /// SHA-256 of the converted artifact; becomes the model revision.
    public let sha256: String
    /// Converter versions, recorded so a re-conversion that behaves
    /// differently is traceable rather than mysterious.
    public let converter: String

    public var identity: EmbedderIdentity {
        EmbedderIdentity(name: name, revision: String(sha256.prefix(8)), dimension: dimension)
    }
}

public enum EmbedderLocator {
    /// Explicit override, then the workspace's own models directory.
    public static let environmentKey = "CYGNUS_EMBED_MODEL"

    /// The model directory for a workspace, or nil when none is
    /// installed. Never throws: absence is a normal state, not an
    /// error, and callers must be able to ask without handling one.
    public static func modelDirectory(workspace: URL) -> URL? {
        let manager = FileManager.default
        if let override = ProcessInfo.processInfo.environment[environmentKey] {
            let url = URL(fileURLWithPath: override)
            return manager.fileExists(atPath: url.path) ? url : nil
        }
        let bundled = workspace.appendingPathComponent("models")
        guard let entries = try? manager.contentsOfDirectory(
            at: bundled, includingPropertiesForKeys: nil) else { return nil }
        // A directory holding a descriptor is a model; anything else is
        // somebody's scratch folder.
        return entries.sorted { $0.path < $1.path }.first {
            manager.fileExists(atPath: $0.appendingPathComponent("descriptor.json").path)
        }
    }

    public static func descriptor(at directory: URL) throws -> EmbedderDescriptor {
        let url = directory.appendingPathComponent("descriptor.json")
        guard let data = try? Data(contentsOf: url) else {
            throw EmbedderError.malformedDescriptor(url.path)
        }
        do {
            return try JSONDecoder().decode(EmbedderDescriptor.self, from: data)
        } catch {
            throw EmbedderError.malformedDescriptor("\(url.path): \(error)")
        }
    }

    /// Human-readable availability, for `cygnus_status`. An agent
    /// reasoning over a corpus needs to know which tiers are real.
    public static func availability(workspace: URL) -> String {
        guard let directory = modelDirectory(workspace: workspace) else {
            return "unavailable (no model; set \(environmentKey) or run tools/convert-embedder.py)"
        }
        guard let descriptor = try? descriptor(at: directory) else {
            return "unavailable (model at \(directory.lastPathComponent) has no readable descriptor)"
        }
        return "ready (\(descriptor.identity.storageKey), \(descriptor.dimension)d)"
    }
}

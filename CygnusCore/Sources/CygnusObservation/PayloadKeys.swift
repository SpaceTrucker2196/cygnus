import CygnusGraph

// Well-known observation payload keys. Extractors write them;
// resolution reads them. Namespaced like every other vocabulary.

public enum ObservationPayload {
    /// Declared name, e.g. "HTTPClient" or "send(_:to:)".
    public static let name = "core:name"
    /// EntityKind raw value the declaration normalizes to.
    public static let declKind = "core:declKind"
    /// Dot-joined nesting path including the name, e.g.
    /// "HTTPClient.send(_:to:)".
    public static let declPath = "core:declPath"
    /// Imported module name (import observations).
    public static let module = "core:module"
    /// Included header path (C include observations).
    public static let header = "core:header"
}

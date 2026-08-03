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
    /// Build target or lane name (build-rule observations).
    public static let buildTarget = "core:buildTarget"
    /// One thing the target is written to depend on, verbatim — a
    /// path, another target, or a variable that was never expanded.
    public static let buildDependency = "core:buildDependency"
    /// Which build system stated it: "make", "fastlane".
    public static let buildSystem = "core:buildSystem"
    /// The target's commands in execution order.
    public static let buildSteps = "core:buildSteps"
    /// Where the target sits in its build file. Make's default goal is
    /// the *first* target, so declaration order is a fact about what
    /// the build does, not a display preference.
    public static let buildOrder = "core:buildOrder"
    /// Author display name, and the address that identifies them.
    public static let authorName = "core:authorName"
    public static let authorEmail = "core:authorEmail"
    /// Commit hash and ISO-8601 author date of an authorship touch.
    public static let commitSHA = "core:commitSHA"
    public static let commitDate = "core:commitDate"
}

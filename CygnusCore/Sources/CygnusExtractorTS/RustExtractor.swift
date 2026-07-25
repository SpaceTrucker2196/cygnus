import Foundation
import CygnusGraph
import CygnusObservation
import CygnusProviders

// tree-sitter-rust extractor: declarations (fn, struct, enum, trait,
// impl, mod, type, const/static) and `use` imports. Literal
// observations only — nesting paths come from enclosing item names;
// reference resolution is a later enrichment.

public struct RustExtractor: ObservationExtractor {
    public let identity = ExtractorIdentity(name: "tree-sitter-rust", version: "0.1.0")

    static let query = """
        (use_declaration argument: (_) @use)
        (function_item name: (identifier) @function)
        (struct_item name: (type_identifier) @struct)
        (enum_item name: (type_identifier) @enum)
        (union_item name: (type_identifier) @struct)
        (trait_item name: (type_identifier) @trait)
        (mod_item name: (identifier) @module)
        (type_item name: (type_identifier) @type)
        (const_item name: (identifier) @const)
        (static_item name: (identifier) @const)
        (macro_definition name: (identifier) @macro)
        """

    /// tree-sitter node kinds that name a scope for nesting paths.
    static let nestingKinds: Set<String> = [
        "function_item", "struct_item", "enum_item", "trait_item",
        "impl_item", "mod_item", "union_item",
    ]

    public init() {}

    public func claims(file: SnapshotFile) -> Bool {
        file.languageHint == "rust" || file.path.hasSuffix(".rs")
    }

    public func extract(file: SnapshotFile, content: Data) throws -> [Observation] {
        let source = String(decoding: content, as: UTF8.self)
        let captures = try TreeSitterHost.captures(.rust, query: Self.query, source: source)

        return captures.compactMap { capture in
            let anchor = SourceAnchor(path: file.path, blob: file.blob, range: capture.range)
            switch capture.name {
            case "use":
                // `std::io::Write` / `crate::foo::Bar` → top segment is
                // the module; keep the leading path as the module name.
                let module = capture.text
                    .trimmingCharacters(in: CharacterSet(charactersIn: "{};, \n\t"))
                guard !module.isEmpty else { return nil }
                return Observation(
                    kind: .importStatement, file: anchor,
                    payload: [ObservationPayload.module: .string(module)],
                    extractor: identity)
            default:
                let kind: EntityKind = switch capture.name {
                case "struct", "type": .type
                case "enum": .enumeration
                case "trait": .interface
                case "module": .type
                case "const": .variable
                default: .function       // function, macro
                }
                let path = TreeSitterHost.declPath(
                    for: capture.node, name: capture.text,
                    nestingKinds: Self.nestingKinds, in: source)
                return Observation(
                    kind: .declaration, file: anchor,
                    payload: [
                        ObservationPayload.name: .string(capture.text),
                        ObservationPayload.declKind: .string(kind.rawValue),
                        ObservationPayload.declPath: .string(path),
                    ],
                    extractor: identity)
            }
        }
    }
}

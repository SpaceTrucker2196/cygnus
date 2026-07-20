import Foundation
import CygnusGraph
import CygnusObservation
import CygnusProviders

public struct PythonExtractor: ObservationExtractor {
    public let identity = ExtractorIdentity(name: "tree-sitter-python", version: "0.1.0")

    static let query = """
        (import_statement name: (dotted_name) @module)
        (import_statement name: (aliased_import name: (dotted_name) @module))
        (import_from_statement module_name: (dotted_name) @module)
        (function_definition name: (identifier) @function)
        (class_definition name: (identifier) @class)
        """

    static let nestingKinds: Set<String> = ["function_definition", "class_definition"]

    public init() {}

    public func claims(file: SnapshotFile) -> Bool {
        file.languageHint == "python" || file.path.hasSuffix(".py")
    }

    public func extract(file: SnapshotFile, content: Data) throws -> [Observation] {
        let source = String(decoding: content, as: UTF8.self)
        let captures = try TreeSitterHost.captures(.python, query: Self.query, source: source)

        return captures.compactMap { capture in
            let anchor = SourceAnchor(path: file.path, blob: file.blob, range: capture.range)
            switch capture.name {
            case "module":
                return Observation(
                    kind: .importStatement, file: anchor,
                    payload: [ObservationPayload.module: .string(capture.text)],
                    extractor: identity)
            case "function", "class":
                let kind: EntityKind = capture.name == "class" ? .type : .function
                // The capture is the name identifier; the declaration
                // node is its parent definition.
                let declNode = capture.node.parent ?? capture.node
                let path = TreeSitterHost.declPath(
                    for: declNode, name: capture.text,
                    nestingKinds: Self.nestingKinds, in: source)
                return Observation(
                    kind: .declaration, file: anchor,
                    payload: [
                        ObservationPayload.name: .string(capture.text),
                        ObservationPayload.declKind: .string(kind.rawValue),
                        ObservationPayload.declPath: .string(path),
                    ],
                    extractor: identity)
            default:
                return nil
            }
        }
    }
}

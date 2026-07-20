import Foundation
import CygnusGraph
import CygnusObservation
import CygnusProviders

public struct CExtractor: ObservationExtractor {
    public let identity = ExtractorIdentity(name: "tree-sitter-c", version: "0.1.0")

    static let query = """
        (preproc_include path: (string_literal) @header)
        (preproc_include path: (system_lib_string) @header)
        (function_definition declarator: (function_declarator declarator: (identifier) @function))
        (struct_specifier name: (type_identifier) @struct body: (_))
        (enum_specifier name: (type_identifier) @enum body: (_))
        """

    public init() {}

    public func claims(file: SnapshotFile) -> Bool {
        file.languageHint == "c" || file.path.hasSuffix(".c") || file.path.hasSuffix(".h")
    }

    public func extract(file: SnapshotFile, content: Data) throws -> [Observation] {
        let source = String(decoding: content, as: UTF8.self)
        let captures = try TreeSitterHost.captures(.c, query: Self.query, source: source)

        return captures.compactMap { capture in
            let anchor = SourceAnchor(path: file.path, blob: file.blob, range: capture.range)
            switch capture.name {
            case "header":
                // "<stdio.h>" or "\"local.h\"" → stdio.h / local.h.
                let header = capture.text.trimmingCharacters(in: CharacterSet(charactersIn: "<>\""))
                return Observation(
                    kind: .importStatement, file: anchor,
                    payload: [ObservationPayload.module: .string(header)],
                    extractor: identity)
            case "function":
                return Observation(
                    kind: .declaration, file: anchor,
                    payload: [
                        ObservationPayload.name: .string(capture.text),
                        ObservationPayload.declKind: .string(EntityKind.function.rawValue),
                        ObservationPayload.declPath: .string(capture.text),
                    ],
                    extractor: identity)
            case "struct", "enum":
                let kind: EntityKind = capture.name == "enum" ? .enumeration : .type
                return Observation(
                    kind: .declaration, file: anchor,
                    payload: [
                        ObservationPayload.name: .string(capture.text),
                        ObservationPayload.declKind: .string(kind.rawValue),
                        ObservationPayload.declPath: .string(capture.text),
                    ],
                    extractor: identity)
            default:
                return nil
            }
        }
    }
}

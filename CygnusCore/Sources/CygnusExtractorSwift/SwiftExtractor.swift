import Foundation
import SwiftParser
import SwiftSyntax
import CygnusGraph
import CygnusObservation
import CygnusProviders

// SwiftSyntax-based extractor: source-level, no build required, works
// on checkouts that don't compile. Emits literal observations only —
// declarations, nesting, imports. Reference resolution is a later
// enrichment (IndexStoreDB), not this extractor's concern.

public struct SwiftExtractor: ObservationExtractor {
    public let identity = ExtractorIdentity(name: "swift-syntax", version: "0.2.0")

    public init() {}

    public func claims(file: SnapshotFile) -> Bool {
        file.languageHint == "swift" || file.path.hasSuffix(".swift")
    }

    public func extract(file: SnapshotFile, content: Data) throws -> [Observation] {
        let source = String(decoding: content, as: UTF8.self)
        let tree = Parser.parse(source: source)
        let visitor = DeclarationVisitor(
            file: file, extractor: identity,
            converter: SourceLocationConverter(fileName: file.path, tree: tree))
        visitor.walk(tree)
        return visitor.observations
    }
}

private final class DeclarationVisitor: SyntaxVisitor {
    let file: SnapshotFile
    let extractor: ExtractorIdentity
    let converter: SourceLocationConverter
    var observations: [Observation] = []
    private var nesting: [String] = []
    private var functionDepth = 0

    init(file: SnapshotFile, extractor: ExtractorIdentity, converter: SourceLocationConverter) {
        self.file = file
        self.extractor = extractor
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    private func anchor(_ node: some SyntaxProtocol) -> SourceAnchor {
        let start = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        let end = converter.location(for: node.endPositionBeforeTrailingTrivia)
        return SourceAnchor(
            path: file.path, blob: file.blob,
            range: SourceRange(startLine: start.line, startColumn: start.column,
                               endLine: end.line, endColumn: end.column))
    }

    private func declare(name: String, kind: EntityKind, node: some SyntaxProtocol) {
        let path = (nesting + [name]).joined(separator: ".")
        observations.append(Observation(
            kind: .declaration,
            file: anchor(node),
            payload: [
                ObservationPayload.name: .string(name),
                ObservationPayload.declKind: .string(kind.rawValue),
                ObservationPayload.declPath: .string(path),
            ],
            extractor: extractor))
    }

    // MARK: Imports

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let module = node.path.map(\.name.text).joined(separator: ".")
        observations.append(Observation(
            kind: .importStatement,
            file: anchor(node),
            payload: [ObservationPayload.module: .string(module)],
            extractor: extractor))
        return .skipChildren
    }

    // MARK: Type-like declarations

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        declare(name: node.name.text, kind: .type, node: node)
        nesting.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { nesting.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        declare(name: node.name.text, kind: .type, node: node)
        nesting.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { nesting.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        declare(name: node.name.text, kind: .type, node: node)
        nesting.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { nesting.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        declare(name: node.name.text, kind: .enumeration, node: node)
        nesting.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { nesting.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        declare(name: node.name.text, kind: .interface, node: node)
        nesting.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { nesting.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        // Members nest under the extended type's name; the extension
        // itself is not an entity. Qualified names ("Array.Index")
        // nest under the base name only — dots are path separators.
        let name = node.extendedType.trimmedDescription
            .split(separator: ".").last.map(String.init) ?? "extension"
        nesting.append(name)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { nesting.removeLast() }

    // MARK: Members

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let params = node.signature.parameterClause.parameters
            .map { "\($0.firstName.text):" }
            .joined()
        declare(name: "\(node.name.text)(\(params))", kind: .function, node: node)
        nesting.append("\(node.name.text)(\(params))")
        functionDepth += 1
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) {
        nesting.removeLast()
        functionDepth -= 1
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        // Function-local variables are noise at architecture scale.
        guard functionDepth == 0 else { return .skipChildren }
        for binding in node.bindings {
            if let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
                declare(name: pattern.identifier.text, kind: .variable, node: binding)
            }
        }
        return .skipChildren
    }
}

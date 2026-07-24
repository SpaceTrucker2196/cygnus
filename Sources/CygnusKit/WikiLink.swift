import Foundation

// Wiki `[[target]]` / `[[target|alias]]` links and the leading YAML
// frontmatter block that sloth's wiki pages carry. Both are pure text
// operations so they unit-test without touching disk.

public struct WikiLink: Sendable, Equatable {
    public let target: String        // page name/slug inside the brackets
    public let alias: String?        // display text after a pipe, if any
    public init(target: String, alias: String?) { self.target = target; self.alias = alias }
    public var displayText: String { alias ?? target }
}

public enum WikiLinkParser {
    private static let regex = try! NSRegularExpression(pattern: #"\[\[([^\]]+)\]\]"#)

    /// Extract every `[[…]]` reference in document order (duplicates kept).
    public static func links(in source: String) -> [WikiLink] {
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: source) else { return nil }
            let inner = String(source[r])
            if let pipe = inner.firstIndex(of: "|") {
                let target = String(inner[..<pipe]).trimmingCharacters(in: .whitespaces)
                let alias = String(inner[inner.index(after: pipe)...]).trimmingCharacters(in: .whitespaces)
                return WikiLink(target: target, alias: alias.isEmpty ? nil : alias)
            }
            return WikiLink(target: inner.trimmingCharacters(in: .whitespaces), alias: nil)
        }
    }

    /// Resolve a link target to a doc path within `knownSlugs` (a map
    /// of normalised slug → repo-relative path). Returns nil (broken
    /// link) when unresolved. Matching is case-insensitive and
    /// space/underscore/hyphen-insensitive.
    public static func resolve(_ link: WikiLink, in knownSlugs: [String: String]) -> String? {
        knownSlugs[slug(link.target)]
    }

    /// Normalise a page name to a slug: lowercase, spaces/underscores →
    /// hyphens, strip a trailing extension.
    public static func slug(_ name: String) -> String {
        var s = name.lowercased()
        if let dot = s.lastIndex(of: "."), s[s.index(after: dot)...].allSatisfy(\.isLetter) {
            s = String(s[..<dot])
        }
        return s
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// The leading `---`…`---` YAML frontmatter block (flat key: value only,
/// which is all sloth's wiki uses — no external YAML dependency).
public enum Frontmatter {
    public struct Parsed: Sendable, Equatable {
        public let fields: [String: String]
        public let bodyRange: Range<String.Index>   // content after the frontmatter
    }

    public static func parse(_ source: String) -> Parsed? {
        let lines = source.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var fields: [String: String] = [:]
        var closingLine: Int?
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" { closingLine = i; break }
            if let colon = lines[i].firstIndex(of: ":") {
                let key = String(lines[i][..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(lines[i][lines[i].index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { fields[key] = value }
            }
        }
        guard let closingLine else { return nil }
        // Compute the body start: char index just past the closing line.
        let consumed = lines[0...closingLine].joined(separator: "\n").count
        let bodyStart = source.index(source.startIndex, offsetBy: min(consumed + 1, source.count))
        return Parsed(fields: fields, bodyRange: bodyStart..<source.endIndex)
    }

    /// Convenience: just the key/value map, or empty if none.
    public static func fields(_ source: String) -> [String: String] {
        parse(source)?.fields ?? [:]
    }
}

import Foundation

// fastlane Fastfile lanes, reduced to what the graph needs: which
// lanes exist and which other lanes each one calls. Line reading, not
// Ruby evaluation — a Fastfile is a program, and we only read it.

public struct FastlaneLane: Sendable, Equatable {
    public let name: String
    public let isPrivate: Bool
    /// Other lanes this one invokes, in call order.
    public let calls: [String]

    public init(name: String, isPrivate: Bool, calls: [String]) {
        self.name = name
        self.isPrivate = isPrivate
        self.calls = calls
    }
}

public enum FastfileLanes {
    /// Parse `lane :name do … end` blocks, matching the `end` at the
    /// lane's own indentation. Only calls to *other lanes in this
    /// file* are recorded: a bare fastlane action is a step, not a
    /// coupling between named things, and guessing which bare word is
    /// a lane would put interpretation in an extractor.
    public static func parse(_ text: String) -> [FastlaneLane] {
        let lines = text.components(separatedBy: "\n")

        struct Block { let name: String; let isPrivate: Bool; let body: [String] }
        var blocks: [Block] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let match = trimmed.firstMatch(of: /^(private_)?lane\s+:(\w+)/) else {
                index += 1
                continue
            }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            var body: [String] = []
            var cursor = index + 1
            while cursor < lines.count {
                let bodyLine = lines[cursor]
                let bodyTrimmed = bodyLine.trimmingCharacters(in: .whitespaces)
                let bodyIndent = bodyLine.prefix { $0 == " " || $0 == "\t" }.count
                if bodyTrimmed == "end", bodyIndent == indent { break }
                body.append(bodyTrimmed)
                cursor += 1
            }
            blocks.append(Block(name: String(match.2), isPrivate: match.1 != nil, body: body))
            index = cursor + 1
        }

        let known = Set(blocks.map(\.name))
        return blocks.map { block in
            var calls: [String] = []
            for line in block.body {
                for candidate in invocations(in: line)
                where known.contains(candidate) && candidate != block.name
                    && !calls.contains(candidate) {
                    calls.append(candidate)
                }
            }
            return FastlaneLane(name: block.name, isPrivate: block.isPrivate, calls: calls)
        }
    }

    /// Identifiers a statement could be invoking. Both `deploy` and
    /// `lane_name(:deploy)` name a lane, so take the leading token and
    /// any `:symbol` arguments and let the caller keep the ones that
    /// are actually lanes.
    static func invocations(in line: String) -> [String] {
        guard !line.isEmpty, !line.hasPrefix("#") else { return [] }
        var result: [String] = []
        if let leading = line.firstMatch(of: /^([a-z_][a-z0-9_]*)/) {
            result.append(String(leading.1))
        }
        for symbol in line.matches(of: /:([a-z_][a-z0-9_]*)/) {
            result.append(String(symbol.1))
        }
        return result
    }
}

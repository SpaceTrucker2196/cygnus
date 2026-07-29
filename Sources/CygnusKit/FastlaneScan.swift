import Foundation

// Fastlane configuration surfaced on the dashboard: lanes from the
// Fastfile, settings from the Appfile, and which lanes CI's workflow
// yml actually invokes. Read-only file parsing — line-level regex
// over the Ruby DSL, enough for display, never executed.

public struct FastlaneInfo: Sendable, Equatable {
    public struct Lane: Sendable, Equatable, Identifiable {
        public let platform: String?      // ios / mac / android…
        public let name: String
        public let desc: String?
        /// A workflow yml invokes this lane.
        public let inCI: Bool
        public var id: String { "\(platform ?? "-")/\(name)" }
        public init(platform: String?, name: String, desc: String?, inCI: Bool) {
            self.platform = platform; self.name = name
            self.desc = desc; self.inCI = inCI
        }
    }

    public struct Setting: Sendable, Equatable, Identifiable {
        public let key: String            // app_identifier, team_id…
        public let value: String
        public var id: String { key }
        public init(key: String, value: String) { self.key = key; self.value = value }
    }

    public let lanes: [Lane]
    public let appfile: [Setting]
    /// Raw fastlane invocations found in workflow ymls ("file: cmd").
    public let ciInvocations: [String]
    /// The laid-out CI flowchart (trigger → lane → actions), for the
    /// Metal flow renderer. Empty when the Fastfile has no lanes.
    public let flow: CIFlow

    public init(lanes: [Lane], appfile: [Setting], ciInvocations: [String],
                flow: CIFlow = CIFlow(nodes: [], edges: [])) {
        self.lanes = lanes; self.appfile = appfile
        self.ciInvocations = ciInvocations; self.flow = flow
    }
}

public enum FastlaneScan {
    /// Nil when the repo has no fastlane/Fastfile.
    public static func scan(repoAt root: URL) -> FastlaneInfo? {
        let fastfile = root.appendingPathComponent("fastlane/Fastfile")
        guard let fastText = try? String(contentsOf: fastfile, encoding: .utf8)
        else { return nil }
        let appText = try? String(
            contentsOf: root.appendingPathComponent("fastlane/Appfile"), encoding: .utf8)
        let invocations = ciFastlaneInvocations(repoAt: root)
        let invoked = Set(invocations.flatMap {
            $0.split(separator: " ").map(String.init)
        })
        let info = FastlaneInfo(
            lanes: lanes(fromFastfile: fastText, ciInvoked: invoked),
            appfile: appText.map(settings(fromAppfile:)) ?? [],
            ciInvocations: invocations)
        return FastlaneInfo(
            lanes: info.lanes, appfile: info.appfile, ciInvocations: info.ciInvocations,
            flow: FastlaneFlowBuilder.build(info: info, fastfileText: fastText))
    }

    /// `platform :ios do` scopes; `desc "…"` attaches to the next
    /// `lane :name do`. Last-seen platform is good enough for display
    /// — Fastfiles nest one level in practice.
    static func lanes(fromFastfile text: String, ciInvoked: Set<String>) -> [FastlaneInfo.Lane] {
        var result: [FastlaneInfo.Lane] = []
        var platform: String?
        var pendingDesc: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let match = line.firstMatch(of: /^platform\s+:(\w+)/) {
                platform = String(match.1)
            } else if let match = line.firstMatch(of: /^desc\s+["'](.+)["']/) {
                pendingDesc = String(match.1)
            } else if let match = line.firstMatch(of: /^(?:private_)?lane\s+:(\w+)/) {
                let name = String(match.1)
                result.append(FastlaneInfo.Lane(
                    platform: platform, name: name, desc: pendingDesc,
                    inCI: ciInvoked.contains(name)))
                pendingDesc = nil
            }
        }
        return result
    }

    /// Appfile lines: `key "value"` / `key("value")` / `key 'value'`.
    static func settings(fromAppfile text: String) -> [FastlaneInfo.Setting] {
        text.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"),
                  let match = line.firstMatch(of: /^(\w+)\s*\(?\s*["']([^"']+)["']/)
            else { return nil }
            return FastlaneInfo.Setting(key: String(match.1), value: String(match.2))
        }
    }

    /// Workflow yml lines that run fastlane, tagged with their file.
    static func ciFastlaneInvocations(repoAt root: URL) -> [String] {
        let workflows = root.appendingPathComponent(".github/workflows")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: workflows.path)
        else { return [] }
        var result: [String] = []
        for entry in entries.sorted()
        where entry.hasSuffix(".yml") || entry.hasSuffix(".yaml") {
            guard let text = try? String(
                contentsOf: workflows.appendingPathComponent(entry), encoding: .utf8)
            else { continue }
            for rawLine in text.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"),
                      let range = line.range(of: #"(bundle exec )?fastlane\s+\S.*"#,
                                             options: .regularExpression)
                else { continue }
                result.append("\(entry): \(line[range])")
            }
        }
        return result
    }
}

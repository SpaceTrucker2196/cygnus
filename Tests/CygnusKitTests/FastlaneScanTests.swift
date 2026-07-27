import Testing
import Foundation
@testable import CygnusKit

struct FastlaneScanTests {
    @Test func parsesLanesSettingsAndCIInvocations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-fastlane-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("fastlane"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".github/workflows"), withIntermediateDirectories: true)

        try """
        default_platform(:ios)

        platform :ios do
          desc "Push a new beta build to TestFlight"
          lane :beta do
            build_app(scheme: "App")
          end

          lane :screenshots do
            capture_screenshots
          end

          private_lane :sign do
            match(type: "appstore")
          end
        end
        """.write(to: root.appendingPathComponent("fastlane/Fastfile"),
                  atomically: true, encoding: .utf8)
        try """
        app_identifier "com.example.demo"
        apple_id("dev@example.com")
        # team_id "COMMENTED"
        team_id 'ABC123'
        """.write(to: root.appendingPathComponent("fastlane/Appfile"),
                  atomically: true, encoding: .utf8)
        try """
        jobs:
          deploy:
            steps:
              - run: bundle exec fastlane ios beta
              # - run: fastlane ios screenshots
        """.write(to: root.appendingPathComponent(".github/workflows/deploy.yml"),
                  atomically: true, encoding: .utf8)

        let info = try #require(FastlaneScan.scan(repoAt: root))
        #expect(info.lanes.map(\.name) == ["beta", "screenshots", "sign"])
        #expect(info.lanes[0].platform == "ios")
        #expect(info.lanes[0].desc == "Push a new beta build to TestFlight")
        #expect(info.lanes[0].inCI)                      // invoked in deploy.yml
        #expect(!info.lanes[1].inCI)                     // only in a comment
        #expect(info.lanes[1].desc == nil)               // desc doesn't leak across lanes
        #expect(info.appfile == [
            .init(key: "app_identifier", value: "com.example.demo"),
            .init(key: "apple_id", value: "dev@example.com"),
            .init(key: "team_id", value: "ABC123"),
        ])
        #expect(info.ciInvocations == ["deploy.yml: bundle exec fastlane ios beta"])

        // No Fastfile → nil, never an empty shell.
        #expect(FastlaneScan.scan(
            repoAt: root.appendingPathComponent("nope")) == nil)
    }
}

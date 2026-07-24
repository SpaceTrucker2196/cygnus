import Testing
import Foundation
@testable import CygnusKit

struct ScreenshotScanTests {
    @Test func scansFastlaneImagesRelativeSortedAndCapped() throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-shots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: repo) }
        let shots = repo.appendingPathComponent("fastlane/screenshots/en-US")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        // More images than the cap, plus a non-image that must be skipped.
        for i in 0..<(GitHubFactoryProvider.screenshotCap + 3) {
            try Data([0x89]).write(to: shots.appendingPathComponent(
                String(format: "%02d-screen.png", i)))
        }
        try "not an image".write(to: shots.appendingPathComponent("notes.txt"),
                                 atomically: true, encoding: .utf8)

        let found = GitHubFactoryProvider.fastlaneScreenshots(repoAt: repo)
        #expect(found.count == GitHubFactoryProvider.screenshotCap)
        #expect(found.first == "fastlane/screenshots/en-US/00-screen.png")
        #expect(found == found.sorted())
        #expect(!found.contains { $0.hasSuffix(".txt") })

        // No fastlane directory → empty, no throw.
        #expect(GitHubFactoryProvider.fastlaneScreenshots(
            repoAt: repo.appendingPathComponent("nope")).isEmpty)
    }
}

import Testing
import Foundation
@testable import CygnusKit

// The Install Factory path: skeleton lands additively, placeholders
// substitute, existing files survive, double-install is a no-op.

struct FactoryInstallerTests {
    /// Build a minimal template + target repo in a temp sandbox so
    /// tests never depend on ~/projects/DF_Template existing.
    private func makeSandbox() throws -> (template: URL, repo: URL, base: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cygnus-installer-\(UUID().uuidString)")
        let template = base.appendingPathComponent("DF_Template")
        let repo = base.appendingPathComponent("target-repo")
        for path in FactoryInstaller.installedPaths {
            let url = template.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "# {{REPO_NAME}} — \(path)\n".write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        return (template, repo, base)
    }

    @Test func installsSkeletonWithPlaceholderSubstitution() throws {
        let (template, repo, base) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: base) }

        let result = try FactoryInstaller(templateURL: template).install(into: repo)
        #expect(result.installed.count == FactoryInstaller.installedPaths.count)
        #expect(result.skipped.isEmpty)

        let ledger = try String(
            contentsOf: repo.appendingPathComponent("LEDGER.md"), encoding: .utf8)
        #expect(ledger.contains("target-repo"))
        #expect(!ledger.contains("{{REPO_NAME}}"))
        #expect(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent(".claude/commands/converge.md").path))
    }

    @Test func neverOverwritesAndReinstallIsNoOp() throws {
        let (template, repo, base) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: base) }

        let existing = "my real factory runbook\n"
        try existing.write(to: repo.appendingPathComponent("FACTORY.md"),
                           atomically: true, encoding: .utf8)

        let installer = FactoryInstaller(templateURL: template)
        let first = try installer.install(into: repo)
        #expect(first.skipped == ["FACTORY.md"])
        #expect(try String(contentsOf: repo.appendingPathComponent("FACTORY.md"),
                           encoding: .utf8) == existing)

        let second = try installer.install(into: repo)
        #expect(second.installed.isEmpty)
        #expect(second.skipped.count == FactoryInstaller.installedPaths.count)
    }

    @Test func missingTemplateThrows() {
        let bogus = URL(fileURLWithPath: "/nonexistent/DF_Template")
        #expect(throws: FactoryInstaller.InstallerError.templateMissing(bogus.path)) {
            try FactoryInstaller(templateURL: bogus)
                .install(into: FileManager.default.temporaryDirectory)
        }
    }

    /// The real DF_Template beside the other repos must contain every
    /// file the installer expects — catches template/installer drift.
    @Test(.enabled(if: FileManager.default.fileExists(
        atPath: FactoryInstaller().templateURL.path)))
    func realTemplateContainsAllInstalledPaths() {
        let template = FactoryInstaller().templateURL
        for path in FactoryInstaller.installedPaths {
            #expect(FileManager.default.fileExists(
                atPath: template.appendingPathComponent(path).path),
                "DF_Template missing \(path)")
        }
    }
}

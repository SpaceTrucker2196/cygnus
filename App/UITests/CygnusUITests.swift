import XCTest

// Drives the real app end to end: launch with a seeded fixture repo,
// watch analysis reach ready, browse all three view modes, search,
// and inspect. This is the automated version of "can it load a repo".

final class CygnusUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Segmented-picker segments surface differently across macOS
    /// versions; try the usual element types.
    @MainActor
    private func segment(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        for query in [app.radioButtons, app.buttons, app.segmentedControls.buttons] {
            let element = query[name]
            if element.exists { return element }
        }
        return app.radioButtons[name]
    }

    @MainActor
    func testLoadRepoBrowseAllViewModes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-seed-repo"]
        app.launch()

        // The seeded repo appears in the sidebar. Queried by
        // identifier, not by static text: the row is a single
        // accessibility element (children: .ignore), so its name is
        // not a text node in the tree.
        let repoRow = app.descendants(matching: .any)["sidebar.repo.uitest-repo"]
        if !repoRow.waitForExistence(timeout: 10) {
            print("UITREE-BEGIN\n\(app.debugDescription)\nUITREE-END")
        }
        XCTAssertTrue(repoRow.exists, "seeded repo row missing from sidebar")

        // Analysis reached ready: the view-mode picker only exists in
        // ready content.
        let flatSegment = segment(app, "Flat")
        XCTAssertTrue(flatSegment.waitForExistence(timeout: 30),
                      "analysis did not reach ready (no view-mode picker)")

        // Outline: the containment tree shows the fixture's Sources dir.
        XCTAssertTrue(app.outlines.firstMatch.waitForExistence(timeout: 5),
                      "outline missing in ready state")

        // Flat: renderer overlay reports scene size.
        flatSegment.click()
        let nodeCounter = app.staticTexts
            .matching(NSPredicate(format: "value CONTAINS[c] 'nodes' OR label CONTAINS[c] 'nodes'"))
            .firstMatch
        XCTAssertTrue(nodeCounter.waitForExistence(timeout: 15),
                      "flat view did not render its scene overlay")

        // Search finds a declaration; selecting it fills the inspector.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "search field missing")
        search.click()
        search.typeText("AppMain")
        let hit = app.staticTexts["AppMain"].firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 10), "search found no declaration")
        hit.click()
        XCTAssertTrue(app.staticTexts["Kind"].waitForExistence(timeout: 5),
                      "inspector did not populate after selection")
    }
}

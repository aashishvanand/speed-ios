import XCTest

/// The macOS half of the accessibility checks the iPhone and Apple TV
/// targets already run: the result scene's element tree, the decorative map
/// staying out of it, and the History sheet's controls and rows. Demo scenes
/// keep every test off the network.
///
/// macOS folds each composite element's value into its label (see
/// `accessibilityLabelAndValue`), so these assertions look for the number in
/// the label rather than in a separate value.
final class MacAccessibilityUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Launches into a demo scene and waits for the demo state to apply.
    private func launch(_ scene: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", scene]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        app.activate()
        _ = app.staticTexts["Speed Test Result"].waitForExistence(timeout: 10)
        return app
    }

    /// Matches by accessibility label whatever element type AppKit chose.
    private func element(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }

    /// AppKit exposes a combined SwiftUI text line as the element's value,
    /// not its label.
    private func text(_ app: XCUIApplication, _ string: String) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "label == %@ OR value == %@", string, string))
            .firstMatch
    }

    func testResultSceneReadsCompletely() {
        let app = launch("result")

        // The hero is one element: name, unit, percentile label and number.
        XCTAssertTrue(element(app, "Download, 90th percentile, 487 Mbps").waitForExistence(timeout: 5))

        // The chips under it carry their own names and values.
        XCTAssertTrue(element(app, "Upload, 92 Mbps").exists)
        XCTAssertTrue(element(app, "Idle Latency, 11 ms").exists)
        XCTAssertTrue(element(app, "Jitter, 0.9 ms").exists)

        // Info rows combine label and value into one readable line each.
        XCTAssertTrue(text(app, "Video Streaming, Great").exists)
        XCTAssertTrue(text(app, "Online Gaming, Great").exists)
        XCTAssertTrue(text(app, "Video Chatting, Great").exists)
        XCTAssertTrue(text(app, "Server, San Jose (SJC)").exists)
        XCTAssertTrue(text(app, "Country, United States").exists)
        XCTAssertTrue(text(app, "Your network, Example Fiber (AS64500)").exists)

        // The IP is a deliberate reveal: named, but hidden until asked.
        let ip = app.buttons["Your IP"]
        XCTAssertTrue(ip.exists)
        let ipValue = ip.value as? String
        XCTAssertEqual(ipValue, "Hidden")

        // Every control is named.
        XCTAssertTrue(app.buttons["Test Again"].exists)
        XCTAssertTrue(app.buttons["History"].exists)
        // A SwiftUI Menu is an NSMenuButton on the Mac, not a button.
        XCTAssertTrue(app.menuButtons["Options"].exists)
    }

    func testMapIsInvisibleToAccessibility() {
        // The colo map is decoration; the rows next to it say the same in
        // words. Hidden elements contribute nothing to the tree.
        let app = launch("details")
        XCTAssertEqual(app.descendants(matching: .map).count, 0)
    }

    func testHistorySheetShowsControlsAndReadableRows() {
        let app = launch("result")
        let history = app.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.click()

        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Clear All"].exists)
        XCTAssertTrue(app.buttons["Export"].exists)

        // Connection, date, every metric's number and the ISP read as one
        // line.
        let row = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Wi-Fi,'"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let label = row.label
        XCTAssertTrue(label.contains("Download, 487 Mbps"))
        XCTAssertTrue(label.contains("Upload, 92 Mbps"))
        XCTAssertTrue(label.contains("Latency, 11 ms"))
        XCTAssertTrue(label.contains("Jitter, 1.6 ms"))
        XCTAssertTrue(label.contains("Example Fiber"))
    }
}

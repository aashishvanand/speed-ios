import XCTest

/// Black-box accessibility audit over the Debug demo scenes (no network
/// traffic — demo mode never starts a run). XCUITest's element tree is what
/// VoiceOver reads, so these assertions are the automatable part of the
/// accessibility pass: every element the TODO's VoiceOver item cares about
/// is checked for a readable name and value.
final class AccessibilityUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Launches into a demo scene and waits for the demo state to apply.
    private func launch(_ scene: String, typeSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", scene]
        if let typeSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", typeSize]
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        _ = app.staticTexts["Speed Test Result"].waitForExistence(timeout: 10)
        return app
    }

    func testResultSceneReadsCompletely() {
        let app = launch("result")

        // The hero is one element: name, unit and percentile label included.
        let hero = app.otherElements["Download, 90th percentile"]
        XCTAssertTrue(hero.exists)
        XCTAssertEqual(hero.value as? String, "487 Mbps")

        // The chips under it carry their own names and values.
        XCTAssertEqual(app.otherElements["Upload"].value as? String, "92 Mbps")
        XCTAssertEqual(app.otherElements["Idle Latency"].value as? String, "11 ms")
        XCTAssertEqual(app.otherElements["Jitter"].value as? String, "0.9 ms")

        // Info rows combine label and value into one readable line each.
        XCTAssertTrue(app.staticTexts["Video Streaming, Great"].exists)
        XCTAssertTrue(app.staticTexts["Online Gaming, Great"].exists)
        XCTAssertTrue(app.staticTexts["Video Chatting, Great"].exists)
        XCTAssertTrue(app.staticTexts["Server, San Jose (SJC)"].exists)
        XCTAssertTrue(app.staticTexts["Country, United States"].exists)
        XCTAssertTrue(app.staticTexts["Your network, Example Fiber (AS64500)"].exists)

        // The IP is a deliberate reveal: named, but hidden until asked.
        let ip = app.buttons["Your IP"]
        XCTAssertTrue(ip.exists)
        XCTAssertEqual(ip.value as? String, "Hidden")

        // Every control is named. Existence in the tree, not
        // `isHittable`: XCUITest's touch-occlusion heuristic is
        // unreliable under the glass materials, and the swipe-delete
        // test below exercises real touch interaction.
        XCTAssertTrue(app.buttons["Test Again"].exists)
        XCTAssertTrue(app.buttons["History"].exists)
        XCTAssertTrue(app.buttons["Options"].exists)
    }

    func testMapIsInvisibleToAccessibility() {
        // The colo map is decoration; the rows below it say the same in
        // words. Hidden elements contribute nothing to the tree.
        let app = launch("details")
        XCTAssertEqual(app.descendants(matching: .map).count, 0)
    }

    func testHistoryRowsReadAsOneElementEach() {
        let app = launch("history")
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Clear All"].exists)
        XCTAssertTrue(app.buttons["Export"].exists)

        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Wi-Fi,'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        // Connection, date, every metric and the ISP read as one line,
        // with the values as the element's value.
        XCTAssertTrue(row.label.contains("Download, Upload, Latency, Jitter"))
        XCTAssertTrue(row.label.contains("Example Fiber"))
        XCTAssertTrue((row.value as? String ?? "").contains("487 Mbps"))
    }

    func testSwipeDeleteRemovesARow() {
        let app = launch("history")
        // The seeded newest row is the only one carrying 487 Mbps.
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Wi-Fi,'"))
        let newest = rows.firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 10))
        XCTAssertTrue((newest.value as? String ?? "").contains("487 Mbps"))

        newest.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "swipe reveals the Delete action")
        delete.tap()

        // The List is lazy, so counting visible rows is unreliable; the
        // first row must now be a different result instead.
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        XCTAssertFalse((newest.value as? String ?? "").contains("487 Mbps"), "the deleted row must not still be first")
    }

    func testLandscapeKeepsEverythingReachable() {
        let app = launch("result")
        XCUIDevice.shared.orientation = .landscapeLeft
        // The interface rotates with the device; the window is now wider
        // than it is tall.
        XCTAssertTrue(app.buttons["Test Again"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        XCTAssertTrue(app.otherElements["Download, 90th percentile"].exists)
        XCTAssertTrue(app.buttons["History"].exists)
        XCUIDevice.shared.orientation = .portrait
    }

    func testLargestTypeSizesStayReadable() {
        // At accessibility sizes the metric chips stack; nothing important
        // may disappear or become untappable.
        let app = launch("result", typeSize: "UICTContentSizeCategoryAccessibilityXXXL")
        XCTAssertTrue(app.otherElements["Download, 90th percentile"].exists)
        XCTAssertTrue(app.buttons["Test Again"].exists)
        XCTAssertTrue(app.buttons["History"].exists)
    }
}

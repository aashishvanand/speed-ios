import XCTest

/// The tvOS hands-on checks, automated with the simulated remote: the
/// result cards below the fold must be reachable by focus and scroll into
/// view, a long press on a history row must open its Delete menu, and the
/// toolbar buttons must keep their names. Demo scenes keep all of this
/// off the network.
final class TVRemoteUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ scene: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", scene]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        _ = app.staticTexts["Speed Test Result"].waitForExistence(timeout: 10)
        return app
    }

    /// True when the element's frame intersects the visible screen — tvOS
    /// lists elements beyond the fold with frames outside the window, so
    /// this is how scrolled-into-view shows up in the tree.
    private func isOnScreen(_ element: XCUIElement, of app: XCUIApplication) -> Bool {
        element.exists && element.frame.maxY > 0 && element.frame.minY < app.frame.height
    }

    func testToolbarButtonsAreNamed() {
        let app = launch("result")
        // The tvOS toolbar shows icons only; without the explicit labels
        // VoiceOver reads the symbols' auto-descriptions instead.
        XCTAssertTrue(app.buttons["History"].exists)
        XCTAssertTrue(app.buttons["Options"].exists)
    }

    func testResultCardsAreReachableByRemote() {
        let app = launch("result")
        let remote = XCUIRemote.shared

        let latencyCard = app.staticTexts["Latency Measurements"]
        let serverCard = app.staticTexts["Server Location"]
        XCTAssertFalse(isOnScreen(latencyCard, of: app), "the bottom card starts below the fold")

        // Walk focus down the screen; the ScrollView must follow focus to
        // the bottom of the results.
        var presses = 0
        while !isOnScreen(latencyCard, of: app) && presses < 10 {
            remote.press(.down)
            presses += 1
            usleep(400_000)
        }

        XCTAssertTrue(isOnScreen(latencyCard, of: app), "focus must scroll the bottom card into view")
        XCTAssertTrue(isOnScreen(serverCard, of: app))
    }

    func testLongPressDeletesARow() {
        let app = launch("history")
        let remote = XCUIRemote.shared
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))

        let newest = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Wi-Fi,'")).firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 10))
        XCTAssertTrue((newest.value as? String ?? "").contains("487 Mbps"))

        // Initial focus lands on the first row; holding select opens its
        // context menu. The action surfaces as an other-typed element,
        // not a button.
        remote.press(.select, forDuration: 1.2)
        let delete = app.otherElements["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "holding select on a row must open its Delete menu")

        // The menu's first item takes focus, so select confirms it.
        remote.press(.select)

        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        XCTAssertFalse((newest.value as? String ?? "").contains("487 Mbps"), "the deleted row must be gone")
    }
}

import XCTest

/// Real gestures against the throwaway demo server only (tools/demo-ha.sh): signs out of whatever server the app had,
/// signs in to http://127.0.0.1:8124. Skipped in the default test run; run with
/// `xcodebuild test ... -only-testing:HomestillUITests`.
final class DemoUITests: XCTestCase {
    func testLongPressSheetAndSlider() {
        let app = XCUIApplication()
        app.launchArguments = ["-signout", "1", "-server", "http://127.0.0.1:8124", "-user", "demo", "-pass", "demo-pass"]
        app.launch()
        let tile = app.descendants(matching: .any)["light.ceiling_lights"]
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        let before = tile.label
        tile.press(forDuration: 0.8)
        let slider = app.sliders["Brightness"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertEqual(app.switches.firstMatch.value as? String, before.contains("On") ? "1" : "0", "the long press must not also toggle")
        slider.adjust(toNormalizedSliderPosition: 0.25)
        sleep(2)
        app.swipeDown(velocity: .fast) // dismiss the sheet
        let label = app.descendants(matching: .any)["light.ceiling_lights"].label
        XCTAssertTrue(label.contains("On · 2"), label) // ~25% came back from the server as the live state
    }

    func testFullScreenCameraRotates() {
        let app = XCUIApplication()
        app.launchArguments = ["-signout", "1", "-server", "http://127.0.0.1:8124", "-user", "demo", "-pass", "demo-pass", "-tab", "cameras"]
        app.launch()
        let card = app.descendants(matching: .any)["camera.demo_camera"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        card.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        let f = app.windows.firstMatch.frame
        XCUIDevice.shared.orientation = .portrait
        XCTAssertGreaterThan(f.width, f.height)
        app.buttons["Close"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    func testTapAndScroll() {
        let app = XCUIApplication()
        app.launchArguments = ["-signout", "1", "-server", "http://127.0.0.1:8124", "-user", "demo", "-pass", "demo-pass"]
        app.launch()
        let tile = app.descendants(matching: .any)["switch.decorative_lights"]
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        sleep(1)
        let wasOn = tile.label.contains("On")
        let (flipped, back) = wasOn ? ("Off", "On") : ("On", "Off")
        tile.tap()
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tile.label.contains(flipped) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 5), .completed, tile.label)
        sleep(6) // past the 5 s optimistic window: the label is now the server's state
        XCTAssertTrue(tile.label.contains(flipped), tile.label)
        tile.tap() // and back
        sleep(2)
        XCTAssertTrue(tile.label.contains(back), tile.label)
        tile.swipeUp(velocity: .fast) // starting on a tile: its tap/long-press gestures must not block scrolling
        app.swipeUp(velocity: .fast)
        XCTAssertTrue(app.descendants(matching: .any)["lock.front_door"].firstMatch.isHittable, "Home scrolls to Other")
    }
}

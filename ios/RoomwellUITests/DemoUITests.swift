import XCTest

/// Real gestures against the throwaway demo server only (tools/demo-ha.sh): signs out of whatever server the app had,
/// signs in to http://127.0.0.1:8124. Skipped in the default test run; run with
/// `xcodebuild test ... -only-testing:RoomwellUITests`.
final class DemoUITests: XCTestCase {
    func testLongPressSheetAndSlider() {
        let app = XCUIApplication()
        app.launchArguments = ["-signout", "1", "-server", "http://127.0.0.1:8124", "-user", "demo", "-pass", "demo-pass"]
        app.launch()
        let tile = app.descendants(matching: .any)["light.ceiling_lights"]
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        tile.press(forDuration: 0.8)
        let slider = app.sliders["Brightness"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        let on = app.switches.firstMatch
        if on.value as? String == "0" { on.switches.firstMatch.tap(); sleep(2) }
        slider.adjust(toNormalizedSliderPosition: 0.25)
        sleep(2)
        app.swipeDown(velocity: .fast) // dismiss the sheet
        let label = app.descendants(matching: .any)["light.ceiling_lights"].label
        XCTAssertTrue(label.contains("On · 2"), label) // ~25% came back from the server as the live state
    }
}

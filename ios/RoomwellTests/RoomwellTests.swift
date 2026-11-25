import XCTest
@testable import Roomwell

@MainActor final class RoomwellTests: XCTestCase {
    func testApplyAddChangeRemove() {
        var st: [String: Entity] = [:]
        var settled = Ha.apply(["a": [
            "light.a": ["s": "on", "a": ["friendly_name": "A", "brightness": 100, "rgb_color": [1, 2, 3]]],
            "sensor.t": ["s": "21", "a": [:]],
        ]], to: &st)
        XCTAssertEqual(Set(st.keys), ["light.a"], "domains we don't show are never stored")
        XCTAssertEqual(settled, ["light.a"])

        settled = Ha.apply(["c": [
            "light.a": ["+": ["s": "off", "a": ["brightness": 50, "new": true]], "-": ["a": ["rgb_color"]]],
            "light.unknown": ["+": ["s": "on"]],
        ]], to: &st)
        XCTAssertEqual(settled, ["light.a"])
        XCTAssertEqual(st["light.a"]?.s, "off")
        XCTAssertEqual(st["light.a"]?.a["brightness"] as? Int, 50)
        XCTAssertEqual(st["light.a"]?.a["friendly_name"] as? String, "A")
        XCTAssertEqual(st["light.a"]?.a["new"] as? Bool, true)
        XCTAssertNil(st["light.a"]?.a["rgb_color"])
        XCTAssertNil(st["light.unknown"])

        settled = Ha.apply(["c": ["light.a": ["+": ["a": ["brightness": 60]]]]], to: &st)
        XCTAssertEqual(settled, [], "attribute-only diffs don't settle an optimistic state")

        // one event with several parts
        Ha.apply(["a": ["switch.b": ["s": "off", "a": [:]]], "r": ["light.a"]], to: &st)
        XCTAssertEqual(Set(st.keys), ["switch.b"])
    }

    func testBuildHome() {
        func e(_ name: String, _ s: String = "on") -> Entity { Entity(s: s, a: ["friendly_name": name]) }
        let states: [String: Entity] = [
            "light.lr": e("Living Room Lights"),          // own area, prefix stripped
            "light.lamp": e("Lamp"),                      // area via its device
            "switch.zed": e("Zed"),                       // device without area → Other
            "fan.hidden": e("Hidden fan"),                // hb
            "switch.config": e("Config switch"),          // ec = 0 (config) still counts
            "light.noreg": e("Bare"),                     // no registry entry → Other
            "scene.movie": e("Movie", "2026-01-01"),      // scene without area → Scenes
            "script.lr": e("Living room script"),         // script with an area stays in the area
            "sensor.temp": e("Temp"),                     // domain not shown
            "camera.door": e("Door"),
            "light.kitchen": e("Kitchen"),                // name == area: nothing left after the prefix, keep it
            "light.ghost": e("Ghost"),                    // unknown area id → Other
        ]
        let reg: [String: Reg] = [
            "light.lr": Reg(device: "d1", area: "living"),
            "light.lamp": Reg(device: "d1"),
            "switch.zed": Reg(device: "d2"),
            "fan.hidden": Reg(device: nil, area: "living", skip: true),
            "switch.config": Reg(device: nil, area: "living", skip: true),
            "script.lr": Reg(device: nil, area: "living"),
            "light.kitchen": Reg(device: nil, area: "kitchen"),
            "light.ghost": Reg(device: nil, area: "nowhere"),
        ]
        let (home, cams) = Ha.build(states: states, reg: reg, deviceArea: ["d1": "bedroom"],
                                    areas: [("kitchen", "Kitchen"), ("bedroom", "Bedroom"), ("living", "Living Room"), ("empty", "Empty")])
        XCTAssertEqual(home.map(\.name), ["Scenes", "Kitchen", "Bedroom", "Living Room", "Other"])
        XCTAssertEqual(home.map { $0.tiles.map(\.name) }, [["Movie"], ["Kitchen"], ["Lamp"], ["Lights", "script"], ["Bare", "Ghost", "Zed"]])
        XCTAssertEqual(cams.map(\.id), ["camera.door"])
    }

    func testParseEntityRegistry() {
        let r = Ha.parseEntityReg(["entities": [
            ["ei": "light.a", "di": "d", "ai": "x"],
            ["ei": "light.b", "hb": true],
            ["ei": "light.c", "ec": 0],
            ["ei": "sensor.d"],
        ]])
        XCTAssertEqual(r, ["light.a": Reg(device: "d", area: "x"), "light.b": Reg(skip: true), "light.c": Reg(skip: true)])
    }

    func testDisplayName() {
        XCTAssertEqual(Ha.displayName("Living Room Lights", area: "Living Room"), "Lights")
        XCTAssertEqual(Ha.displayName("living room lights", area: "Living Room"), "lights")
        XCTAssertEqual(Ha.displayName("Living Roomba", area: "Living Room"), "Living Roomba")
        XCTAssertEqual(Ha.displayName("Living Room", area: "Living Room"), "Living Room")
        XCTAssertEqual(Ha.displayName("Lights", area: nil), "Lights")
    }

    func testLockTap() {
        XCTAssertEqual(Ha.lockTap("locked"), .confirmUnlock)
        XCTAssertEqual(Ha.lockTap("unlocked"), .lock)
        XCTAssertEqual(Ha.lockTap("open"), .lock)
        XCTAssertEqual(Ha.lockTap("jammed"), .lock)
        for s in ["locking", "unlocking", "opening", "unavailable"] { XCTAssertEqual(Ha.lockTap(s), .none) }
    }

    func testNeedsRefresh() {
        let now = Date()
        XCTAssertTrue(Ha.needsRefresh(token: nil, expiry: now + 1800, now: now))
        XCTAssertTrue(Ha.needsRefresh(token: "t", expiry: now + 59, now: now))
        XCTAssertTrue(Ha.needsRefresh(token: "t", expiry: now - 10, now: now))
        XCTAssertFalse(Ha.needsRefresh(token: "t", expiry: now + 61, now: now))
    }

    func testStateTextAndUrls() {
        XCTAssertEqual(Ha.stateText(Tile(id: "light.a", name: "", s: "on", brightness: 153)), "On · 60%")
        XCTAssertEqual(Ha.stateText(Tile(id: "light.a", name: "", s: "off")), "Off")
        XCTAssertEqual(Ha.stateText(Tile(id: "cover.a", name: "", s: "open", position: 70)), "Open · 70%")
        XCTAssertEqual(Ha.stateText(Tile(id: "switch.a", name: "", s: "unavailable")), "Unavailable")
        XCTAssertEqual(Ha.stateText(Tile(id: "button.a", name: "", s: "unknown")), "Press")
        XCTAssertEqual(Ha.candidates(" ha.local:8123/ "), ["https://ha.local:8123", "http://ha.local:8123"])
        XCTAssertEqual(Ha.candidates("http://x//"), ["http://x"])
        XCTAssertEqual(Ha.formBody(["b": "a+b c&d=é", "a": "1"]), "a=1&b=a%2Bb%20c%26d%3D%C3%A9")
    }
}

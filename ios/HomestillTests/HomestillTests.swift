import XCTest
@testable import Homestill

@MainActor final class HomestillTests: XCTestCase {
    func e(_ s: String, _ a: [String: Any] = [:]) -> Entity { Entity(s: s, a: a.mapValues(JSON.init)) }
    func t(_ id: String, _ s: String, _ a: [String: Any] = [:], dp: Int? = nil) -> Tile {
        Tile(id: id, name: "N", s: s, a: a.mapValues(JSON.init), dp: dp)
    }

    func testApplyAddChangeRemove() {
        var st: [String: Entity] = [:]
        var settled = Ha.apply(["a": [
            "light.a": ["s": "on", "a": ["friendly_name": "A", "brightness": 100, "rgb_color": [1, 2, 3]]],
            "person.t": ["s": "home", "a": [:]],
        ]], to: &st)
        XCTAssertEqual(Set(st.keys), ["light.a"], "domains we don't show are never stored")
        XCTAssertEqual(settled, ["light.a"])

        settled = Ha.apply(["c": [
            "light.a": ["+": ["s": "off", "a": ["brightness": 50, "new": true]], "-": ["a": ["rgb_color"]]],
            "light.unknown": ["+": ["s": "on"]],
        ]], to: &st)
        XCTAssertEqual(settled, ["light.a"])
        XCTAssertEqual(st["light.a"]?.s, "off")
        XCTAssertEqual(st["light.a"]?.a["brightness"], .num(50))
        XCTAssertEqual(st["light.a"]?.a["friendly_name"], .str("A"))
        XCTAssertEqual(st["light.a"]?.a["new"], .bool(true))
        XCTAssertNil(st["light.a"]?.a["rgb_color"])
        XCTAssertNil(st["light.unknown"])

        settled = Ha.apply(["c": ["light.a": ["+": ["a": ["brightness": 60]]]]], to: &st)
        XCTAssertEqual(settled, [], "attribute-only diffs don't settle an optimistic state")

        // one event with several parts
        Ha.apply(["a": ["switch.b": ["s": "off", "a": [:]]], "r": ["light.a"]], to: &st)
        XCTAssertEqual(Set(st.keys), ["switch.b"])
    }

    func testAttributesSurviveTheSnapshot() throws {
        let raw = try JSONSerialization.jsonObject(with: Data(#"{"b":true,"n":1,"x":2.5,"s":"s","l":["a",null],"o":{"k":false}}"#.utf8))
        let tile = Tile(id: "media_player.a", name: "A", s: "on", a: (raw as! [String: Any]).mapValues(JSON.init), dp: 1, ptz: "camera.x")
        XCTAssertEqual(tile.a["b"], .bool(true))
        XCTAssertEqual(tile.a["n"], .num(1), "1 is a number, not true")
        XCTAssertEqual(tile.a["l"], .arr([.str("a"), .null]))
        XCTAssertEqual(try JSONDecoder().decode(Tile.self, from: JSONEncoder().encode(tile)), tile)
    }

    func testBuildHome() {
        func e(_ name: String, _ s: String = "on", _ a: [String: Any] = [:]) -> Entity { self.e(s, a.merging(["friendly_name": name]) { a, _ in a }) }
        let states: [String: Entity] = [
            "light.lr": e("Living Room Lights"),          // own area, prefix stripped
            "light.lamp": e("Lamp"),                      // area via its device
            "switch.zed": e("Zed"),                       // device without area → Other
            "fan.hidden": e("Hidden fan"),                // hb
            "switch.config": e("Config switch"),          // ec = 0 (config) still counts
            "light.noreg": e("Bare"),                     // no registry entry → Other
            "scene.movie": e("Movie", "2026-01-01"),      // scene without area → Scenes
            "script.lr": e("Living room script"),         // script with an area stays in the area
            "person.me": e("Me"),                         // domain not shown
            "camera.door": e("Door"),
            "light.kitchen": e("Kitchen"),                // name == area: nothing left after the prefix, keep it
            "light.ghost": e("Ghost"),                    // unknown area id → Other
            "sensor.temp": e("Air", "21.5"),              // reading in an area: after the controls
            "number.vol": e("A volume", "4"),             // a setting sorts with the readings, even before "Air"
            "sensor.noarea": e("Loose", "1"),             // reading without an area: not shown
            "sensor.gone": e("Gone", "unavailable"),      // reading without a state: not shown
            "binary_sensor.what": e("What", "unknown"),
            "sensor.when": e("When", "2026-01-01T00:00:00+00:00", ["device_class": "timestamp"]),
            "climate.lr": e("Zzz heat"),                  // a control: before the readings despite its name
        ]
        let reg: [String: Reg] = [
            "light.lr": Reg(device: "d1", area: "living"),
            "light.lamp": Reg(device: "d1"),
            "switch.zed": Reg(device: "d2"),
            "fan.hidden": Reg(device: nil, area: "living", hidden: true),
            "switch.config": Reg(device: nil, area: "living", category: true),
            "script.lr": Reg(device: nil, area: "living"),
            "light.kitchen": Reg(device: nil, area: "kitchen"),
            "light.ghost": Reg(device: nil, area: "nowhere"),
            "sensor.temp": Reg(area: "living"), "number.vol": Reg(area: "living"), "sensor.gone": Reg(area: "living"),
            "binary_sensor.what": Reg(area: "living"), "sensor.when": Reg(area: "living"), "climate.lr": Reg(area: "living"),
        ]
        let (home, cams) = Ha.build(states: states, reg: reg, deviceArea: ["d1": "bedroom"],
                                    areas: [("kitchen", "Kitchen"), ("bedroom", "Bedroom"), ("living", "Living Room"), ("empty", "Empty")])
        XCTAssertEqual(home.map(\.name), ["Scenes", "Kitchen", "Bedroom", "Living Room", "Other"])
        XCTAssertEqual(home.map { $0.tiles.map(\.name) },
                       [["Movie"], ["Kitchen"], ["Lamp"], ["Lights", "script", "Zzz heat", "A volume", "Air"], ["Bare", "Ghost", "Zed"]])
        XCTAssertEqual(cams.map(\.id), ["camera.door"])
    }

    func testPanTiltRule() {
        func cams(_ reg: [String: Reg]) -> [String: String?] {
            let states = Dictionary(uniqueKeysWithValues: reg.keys.map { ($0, e("idle", ["friendly_name": $0])) })
            let c = Ha.build(states: states, reg: reg, deviceArea: ["dev": "yard"], areas: [("yard", "Yard"), ("hall", "Hall")]).cameras
            return Dictionary(uniqueKeysWithValues: c.map { ($0.id, $0.ptz) })
        }
        // its own platform is onvif
        XCTAssertEqual(cams(["camera.a": Reg(area: "hall", pl: "onvif"), "camera.b": Reg(area: "hall", pl: "tapo")]),
                       ["camera.a": "camera.a", "camera.b": nil])
        // the only shown camera in an area (here via its device) with a hidden onvif camera: moves that one
        XCTAssertEqual(cams(["camera.tapo": Reg(device: "dev", pl: "tapo"), "camera.onvif": Reg(area: "yard", hidden: true, pl: "onvif"),
                             "camera.hall": Reg(area: "hall", pl: "tapo")]),
                       ["camera.tapo": "camera.onvif", "camera.hall": nil])
        // two shown cameras in that area: neither moves
        XCTAssertEqual(cams(["camera.a": Reg(area: "yard", pl: "tapo"), "camera.b": Reg(area: "yard", pl: "tapo"),
                             "camera.onvif": Reg(area: "yard", hidden: true, pl: "onvif")]),
                       ["camera.a": nil, "camera.b": nil])
        // hidden but not onvif, or onvif but not hidden (a config category): no
        XCTAssertEqual(cams(["camera.a": Reg(area: "yard"), "camera.h": Reg(area: "yard", hidden: true, pl: "tapo"),
                             "camera.c": Reg(area: "hall"), "camera.o": Reg(area: "hall", category: true, pl: "onvif")]),
                       ["camera.a": nil, "camera.c": nil])
    }

    func testParseEntityRegistry() {
        let r = Ha.parseEntityReg(["entities": [
            ["ei": "light.a", "di": "d", "ai": "x"],
            ["ei": "light.b", "hb": true],
            ["ei": "light.c", "ec": 0],
            ["ei": "sensor.d", "dp": 1, "pl": "demo"],
            ["ei": "camera.e", "hb": true, "pl": "onvif"],
            ["ei": "person.f"],
        ]])
        XCTAssertEqual(r, ["light.a": Reg(device: "d", area: "x"), "light.b": Reg(hidden: true), "light.c": Reg(category: true),
                           "sensor.d": Reg(pl: "demo", dp: 1), "camera.e": Reg(hidden: true, pl: "onvif")])
    }

    func testDisplayName() {
        XCTAssertEqual(Ha.displayName("Living Room Lights", area: "Living Room"), "Lights")
        XCTAssertEqual(Ha.displayName("living room lights", area: "Living Room"), "lights")
        XCTAssertEqual(Ha.displayName("Living Roomba", area: "Living Room"), "Living Roomba")
        XCTAssertEqual(Ha.displayName("Living Room", area: "Living Room"), "Living Room")
        XCTAssertEqual(Ha.displayName("Lights", area: nil), "Lights")
    }

    func testTapActions() {
        XCTAssertEqual(Ha.tapAction(t("lock.a", "locked")), .confirmUnlock)
        for s in ["unlocked", "open", "jammed"] { XCTAssertEqual(Ha.tapAction(t("lock.a", s)), .call("lock", optimistic: "locking")) }
        for s in ["locking", "unlocking", "opening", "unavailable"] { XCTAssertEqual(Ha.tapAction(t("lock.a", s)), TapAction.none) }

        XCTAssertEqual(Ha.tapAction(t("vacuum.v", "cleaning", ["supported_features": 4 | 8192])), .call("pause"))
        XCTAssertEqual(Ha.tapAction(t("vacuum.v", "cleaning", ["supported_features": 16])), .call("return_to_base"))
        XCTAssertEqual(Ha.tapAction(t("vacuum.v", "docked", ["supported_features": 8192])), .call("start"))
        XCTAssertEqual(Ha.tapAction(t("vacuum.v", "docked", ["supported_features": 4])), .sheet)

        XCTAssertEqual(Ha.tapAction(t("media_player.m", "playing")), .call("media_play_pause"))
        XCTAssertEqual(Ha.tapAction(t("media_player.m", "paused")), .call("media_play_pause"))
        XCTAssertEqual(Ha.tapAction(t("media_player.m", "off", ["supported_features": 128])), .call("turn_on"))
        XCTAssertEqual(Ha.tapAction(t("media_player.m", "off")), .sheet)
        XCTAssertEqual(Ha.tapAction(t("media_player.m", "idle", ["supported_features": 128])), .sheet)

        for s in ["disarmed", "armed_away", "triggered", "pending"] {
            XCTAssertEqual(Ha.tapAction(t("alarm_control_panel.a", s, ["supported_features": 63])), .sheet, "the alarm never acts on a tap")
        }
        XCTAssertEqual(Ha.tapAction(t("lawn_mower.l", "mowing", ["supported_features": 2])), .call("pause"))
        XCTAssertEqual(Ha.tapAction(t("lawn_mower.l", "docked", ["supported_features": 1])), .call("start_mowing"))
        XCTAssertEqual(Ha.tapAction(t("valve.v", "open")), .call("toggle", optimistic: "closed"))
        XCTAssertEqual(Ha.tapAction(t("valve.v", "closed")), .call("toggle", optimistic: "open"))
        XCTAssertEqual(Ha.tapAction(t("remote.r", "on")), .call("toggle", optimistic: "off"))
        XCTAssertEqual(Ha.tapAction(t("siren.s", "off")), .sheet)
        XCTAssertEqual(Ha.tapAction(t("climate.c", "heat")), .sheet)
        XCTAssertEqual(Ha.tapAction(t("select.s", "a")), .menu)
        XCTAssertEqual(Ha.tapAction(t("number.n", "1")), .sheet)
        XCTAssertEqual(Ha.tapAction(t("sensor.s", "1")), TapAction.none)
        XCTAssertEqual(Ha.tapAction(t("button.b", "unknown")), .call("press"))
    }

    func testActive() {
        XCTAssertTrue(Ha.active(t("climate.c", "heat")))
        XCTAssertFalse(Ha.active(t("climate.c", "off")))
        XCTAssertTrue(Ha.active(t("valve.v", "opening")))
        XCTAssertFalse(Ha.active(t("media_player.m", "paused")))
        XCTAssertTrue(Ha.active(t("alarm_control_panel.a", "armed_night")))
        XCTAssertTrue(Ha.active(t("alarm_control_panel.a", "triggered")))
        XCTAssertFalse(Ha.active(t("alarm_control_panel.a", "arming")))
        XCTAssertFalse(Ha.active(t("binary_sensor.b", "on")), "readings are never tinted")
        XCTAssertFalse(Ha.active(t("switch.s", "unavailable")))
    }

    func testNeedsRefresh() {
        let now = Date()
        XCTAssertTrue(Ha.needsRefresh(token: nil, expiry: now + 1800, now: now))
        XCTAssertTrue(Ha.needsRefresh(token: "t", expiry: now + 59, now: now))
        XCTAssertTrue(Ha.needsRefresh(token: "t", expiry: now - 10, now: now))
        XCTAssertFalse(Ha.needsRefresh(token: "t", expiry: now + 61, now: now))
    }

    func testStateTexts() {
        func s(_ id: String, _ st: String, _ a: [String: Any] = [:], dp: Int? = nil) -> String { Ha.stateText(t(id, st, a, dp: dp)) }
        XCTAssertEqual(s("light.a", "on", ["brightness": 153]), "On · 60%")
        XCTAssertEqual(s("light.a", "off"), "Off")
        XCTAssertEqual(s("cover.a", "open", ["current_position": 70]), "Open · 70%")
        XCTAssertEqual(s("switch.a", "unavailable"), "Unavailable")
        XCTAssertEqual(s("button.a", "unknown"), "Press")
        XCTAssertEqual(s("siren.a", "on"), "On")
        XCTAssertEqual(s("valve.a", "closing", ["current_position": 30]), "Closing · 30%")
        XCTAssertEqual(s("valve.a", "open"), "Open")
        XCTAssertEqual(s("climate.a", "heat", ["current_temperature": 21.5, "temperature_unit": "°C"]), "Heat · 21.5 °C")
        XCTAssertEqual(s("climate.a", "off", ["current_temperature": 19, "temperature_unit": "°C"]), "Off · 19 °C")
        XCTAssertEqual(s("climate.a", "heat_cool"), "Heat cool")
        XCTAssertEqual(s("water_heater.a", "eco", ["operation_mode": "high_demand", "temperature": 48.5, "temperature_unit": "°C"]),
                       "High demand · 48.5 °C")
        XCTAssertEqual(s("humidifier.a", "on", ["humidity": 65]), "On · 65%")
        XCTAssertEqual(s("humidifier.a", "off", ["humidity": 65]), "Off")
        XCTAssertEqual(s("media_player.a", "playing", ["media_title": "Song"]), "Song")
        XCTAssertEqual(s("media_player.a", "paused", ["media_title": "Song"]), "Song")
        XCTAssertEqual(s("media_player.a", "idle", ["media_title": "Song"]), "Idle")
        XCTAssertEqual(s("media_player.a", "playing"), "Playing")
        XCTAssertEqual(s("vacuum.a", "docked"), "Docked")
        XCTAssertEqual(s("lawn_mower.a", "mowing"), "Mowing")
        XCTAssertEqual(s("alarm_control_panel.a", "armed_home"), "Armed home")
        XCTAssertEqual(s("alarm_control_panel.a", "armed_custom_bypass"), "Armed custom bypass")
        XCTAssertEqual(s("number.a", "42.0", ["unit_of_measurement": "%"]), "42 %")
        XCTAssertEqual(s("number.a", "0.42"), "0.42")
        XCTAssertEqual(s("select.a", "ridiculous_speed"), "ridiculous_speed")
        XCTAssertEqual(s("sensor.a", "15.637", ["unit_of_measurement": "°C"], dp: 1), "15.6 °C")
        XCTAssertEqual(s("sensor.a", "15.637", ["unit_of_measurement": "°C"]), "15.637 °C")
        XCTAssertEqual(s("sensor.a", "15", dp: 2), "15.00")
        XCTAssertEqual(s("sensor.a", "eco"), "eco")
        XCTAssertEqual(s("binary_sensor.a", "on", ["device_class": "door"]), "Open")
        XCTAssertEqual(s("binary_sensor.a", "off", ["device_class": "motion"]), "Clear")
        XCTAssertEqual(s("binary_sensor.a", "on", ["device_class": "moisture"]), "Wet")
        XCTAssertEqual(s("binary_sensor.a", "on", ["device_class": "smoke"]), "Detected")
        XCTAssertEqual(s("binary_sensor.a", "off", ["device_class": "problem"]), "OK")
        XCTAssertEqual(s("binary_sensor.a", "on", ["device_class": "lock"]), "Unlocked")
        XCTAssertEqual(s("binary_sensor.a", "on", ["device_class": "battery"]), "Low")
        XCTAssertEqual(s("binary_sensor.a", "off", ["device_class": "connectivity"]), "Disconnected")
        XCTAssertEqual(s("binary_sensor.a", "on", ["device_class": "battery_charging"]), "On")
        XCTAssertEqual(s("weather.a", "partlycloudy", ["temperature": 21.6, "temperature_unit": "°C"]), "Partly cloudy · 21.6 °C")
        XCTAssertEqual(s("weather.a", "clear-night", ["temperature": -3, "temperature_unit": "°C"]), "Clear night · -3 °C")
        XCTAssertEqual(s("weather.a", "sunny"), "Sunny")
    }

    func testUrlsAndForms() {
        XCTAssertEqual(Ha.candidates(" ha.local:8123/ "), ["https://ha.local:8123", "http://ha.local:8123"])
        XCTAssertEqual(Ha.candidates("http://x//"), ["http://x"])
        XCTAssertEqual(Ha.formBody(["b": "a+b c&d=é", "a": "1"]), "a=1&b=a%2Bb%20c%26d%3D%C3%A9")
        XCTAssertEqual(SendSlider.decimals(1), 0)
        XCTAssertEqual(SendSlider.decimals(0.5), 1)
        XCTAssertEqual(SendSlider.decimals(0.01), 2)
        XCTAssertEqual(Ha.fmt(21.1 + 0.1), "21.2")
        XCTAssertEqual(Ha.fmt(-3), "-3")
        XCTAssertEqual(Ha.fmt(0.42), "0.42")
    }
}

import SwiftUI
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
        XCTAssertEqual(s("alarm_control_panel.a", "armed_custom_bypass"), "Armed custom")
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

    func testBulbIconsStandOutFromTheirCard() {
        func lum(_ c: Color) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
            let l = [r, g, b].map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2]
        }
        for dark in [false, true] {
            for c in [Color(red: 0, green: 0, blue: 1), Color(red: 1, green: 1, blue: 0), Color(red: 1, green: 0.9, blue: 0.8), .orange] {
                let page: CGFloat = dark ? 0 : 1, icon = lum(TileView.legible(c, dark: dark))
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(c).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
                let bg = lum(Color(red: r * 0.22 + page * 0.78, green: g * 0.22 + page * 0.78, blue: b * 0.22 + page * 0.78))
                XCTAssertGreaterThanOrEqual((max(icon, bg) + 0.05) / (min(icon, bg) + 0.05), 2.99, "\(c) dark=\(dark)")
            }
        }
    }

    // MARK: Customizing Home (SPEC test vectors)

    let sections: [Homestill.Section] = {
        typealias S = Homestill.Section
        func t(_ id: String, _ name: String, full: String? = nil) -> Tile { Tile(id: id, name: name, s: "on", full: full ?? name) }
        let a: [Tile] = [t("light.a1", "One"), t("light.a2", "Two"), t("light.a4", "Four"), t("sensor.a3", "Three")]
        return [
            S(key: "scenes", name: "Scenes", tiles: [t("scene.s", "S")]),
            S(key: "area:a", name: "A", tiles: a),
            S(key: "area:b", name: "B", tiles: [t("light.b1", "Lamp", full: "B Lamp")]),
            S(key: "other", name: "Other", tiles: [t("switch.o", "O")]),
        ]
    }()

    /// "A[a1 a2] B[]" with ids short of their domain.
    func show(_ rooms: [Room]) -> String {
        rooms.map { r in "\(r.name)[\(r.tiles.map { String($0.id.split(separator: ".")[1]) }.joined(separator: " "))]" }.joined(separator: " ")
    }
    func arranged(_ json: String?) -> [Room] { Ha.arrange(sections, Layout.parse(json)) }
    func room(_ rooms: [Room], _ key: String) -> Room { rooms.first { $0.key == key }! }

    func testArrangeVectors() {
        XCTAssertEqual(show(arranged(nil)), "Scenes[s] A[a1 a2 a4 a3] B[b1] Other[o]")
        XCTAssertEqual(show(arranged("{}")), "Scenes[s] A[a1 a2 a4 a3] B[b1] Other[o]")
        XCTAssertEqual(show(arranged(#"{"order":["area:b"]}"#)), "B[b1] Scenes[s] A[a1 a2 a4 a3] Other[o]")
        XCTAssertEqual(show(arranged(#"{"tiles":{"area:a":["light.a2","light.a1"]}}"#)), "Scenes[s] A[a2 a1 a4 a3] B[b1] Other[o]")
        XCTAssertEqual(show(arranged(#"{"tiles":{"area:a":["sensor.zz","light.a1"]}}"#)), "Scenes[s] A[a1 a2 a4 a3] B[b1] Other[o]")

        let moved = arranged(#"{"moved":{"light.b1":"area:a"},"tiles":{"area:a":["light.a1","light.b1"]}}"#)
        XCTAssertEqual(show(moved), "Scenes[s] A[a1 b1 a2 a4 a3] B[] Other[o]")
        XCTAssertEqual(room(moved, "area:a").tiles.map(\.moved), [false, true, false, false, false])
        XCTAssertEqual(room(moved, "area:a").tiles[1].t.name, "B Lamp", "a moved tile shows its full name")
        XCTAssertEqual(room(moved, "area:a").tiles[0].t.name, "One")
        XCTAssertEqual(show(Ha.visible(moved)), "Scenes[s] A[a1 b1 a2 a4 a3] Other[o]", "B has no tiles: not on Home")

        let gone = arranged(#"{"moved":{"light.a1":"area:gone"}}"#)
        XCTAssertEqual(show(gone), "Scenes[s] A[a1 a2 a4 a3] B[b1] Other[o]")
        XCTAssertFalse(room(gone, "area:a").tiles[0].moved)
        XCTAssertEqual(room(gone, "area:a").tiles[0].t.name, "One")

        let hidden = arranged(#"{"hidden":["light.a2"],"hiddenRooms":["other"]}"#)
        XCTAssertEqual(show(Ha.visible(hidden)), "Scenes[s] A[a1 a4 a3] B[b1]")
        XCTAssertEqual(show(hidden), "Scenes[s] A[a1 a2 a4 a3] B[b1] Other[o]", "the editor lists hidden ones")
        XCTAssertEqual(room(hidden, "area:a").tiles.filter(\.hidden).map(\.id), ["light.a2"])
        XCTAssertEqual(hidden.filter(\.hidden).map(\.key), ["other"])

        XCTAssertEqual(show(arranged(#"{"order":["zz","area:a"]}"#)), "A[a1 a2 a4 a3] Scenes[s] B[b1] Other[o]")
    }

    func testBrokenLayoutIsTheDefault() {
        XCTAssertEqual(Layout.parse("not json"), Layout())
        XCTAssertEqual(Layout.parse(#"{"order":5}"#), Layout())
        XCTAssertEqual(Layout.parse(#"{"order":["area:b"],"future":1}"#), Layout(order: ["area:b"]))
    }

    func testSavingEditsTheStoredLayout() {
        // a move in A keeps the not-current sensor.zz at the end
        var l = Layout.parse(#"{"tiles":{"area:a":["sensor.zz","light.a1"]}}"#)
        l.moveTile("light.a4", to: "area:a", at: 0, sections)
        XCTAssertEqual(l.tiles["area:a"], ["light.a4", "light.a1", "light.a2", "sensor.a3", "sensor.zz"])
        XCTAssertEqual(l.moved, [:])
        XCTAssertEqual(show(Ha.arrange(sections, l)), "Scenes[s] A[a4 a1 a2 a3] B[b1] Other[o]")

        // moving a room keeps the not-current order keys at the end
        l = Layout.parse(#"{"order":["zz","area:a"]}"#)
        l.moveRoom("area:b", to: 0, sections)
        XCTAssertEqual(l.order, ["area:b", "area:a", "scenes", "other", "zz"])

        // to another room and back: `moved` only holds tiles out of their own room
        l = Layout()
        l.moveTile("light.b1", to: "area:a", at: 1, sections)
        XCTAssertEqual(l.moved, ["light.b1": "area:a"])
        XCTAssertEqual(l.tiles["area:a"], ["light.a1", "light.b1", "light.a2", "light.a4", "sensor.a3"])
        XCTAssertEqual(show(Ha.arrange(sections, l)), "Scenes[s] A[a1 b1 a2 a4 a3] B[] Other[o]")
        l.moveTile("light.b1", to: "area:b", at: 0, sections)
        XCTAssertEqual(l.moved, [:])
        XCTAssertEqual(show(Ha.arrange(sections, l)), "Scenes[s] A[a1 a2 a4 a3] B[b1] Other[o]")
        l.moveTile("light.b1", to: "area:gone", at: 0, sections)
        XCTAssertEqual(l.moved, [:], "never moves to a room that isn't there")

        // eye toggles
        l = Layout()
        l.toggle(\.hidden, "light.a2"); l.toggle(\.hiddenRooms, "other")
        XCTAssertEqual(l, Layout(hiddenRooms: ["other"], hidden: ["light.a2"]))
        l.toggle(\.hidden, "light.a2")
        XCTAssertEqual(l.hidden, [])

        // what is stored reads back the same
        l = Layout(order: ["area:b"], tiles: ["area:a": ["light.a2"]], moved: ["light.b1": "area:a"])
        XCTAssertEqual(Layout.parse(String(decoding: try! JSONEncoder().encode(l), as: UTF8.self)), l)
    }

    func testSnapshotKeysAndOldCache() throws {
        let (home, _) = Ha.build(states: ["light.x": e("on", ["friendly_name": "Garage X"]), "scene.s": e("2026-01-01")],
                                 reg: ["light.x": Reg(area: "other")], deviceArea: [:], areas: [("other", "Garage")])
        XCTAssertEqual(home.map(\.key), ["scenes", "area:other"], "an area whose id is \"other\" stays area:other")
        XCTAssertEqual(home[1].tiles[0].name, "X")
        XCTAssertEqual(home[1].tiles[0].full, "Garage X")
        let snap = Ha.Snapshot(home: home, cameras: [])
        XCTAssertEqual(try JSONDecoder().decode(Ha.Snapshot.self, from: JSONEncoder().encode(snap)).home, home)
        let old = #"{"home":[{"id":"kitchen","name":"Kitchen","tiles":[{"id":"light.k","name":"K","s":"on","a":{}}]}],"cameras":[]}"#
        XCTAssertNil(try? JSONDecoder().decode(Ha.Snapshot.self, from: Data(old.utf8)), "a cache from before keys is ignored")
    }
}

package com.borodutch.homestill

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ModelTest {
    private fun ents(json: String) = mutableMapOf<String, Ent>().also { applyEvent(it, JSONObject(json)) }

    @Test fun addChangeRemove() {
        val m = ents("""{"a":{"light.a":{"s":"off","a":{"friendly_name":"A","brightness":null,"effect":"x"},"c":"1","lc":1},
            "person.t":{"s":"home","a":{}},"camera.c":{"s":"idle","a":{}}}}""")
        assertEquals(setOf("light.a", "camera.c"), m.keys) // other domains dropped
        val t = applyEvent(m, JSONObject("""{"c":{"light.a":{"+":{"s":"on","a":{"brightness":255},"lc":2},"-":{"a":["effect"]}},"person.t":{"+":{"s":"away"}}}}"""))
        assertEquals(setOf("light.a"), t)
        val a = m["light.a"]!!
        assertEquals("on", a.s)
        assertEquals(255, a.a.getInt("brightness"))
        assertEquals("A", a.a.getString("friendly_name"))
        assertFalse(a.a.has("effect"))
        // attribute-only diff keeps the state
        applyEvent(m, JSONObject("""{"c":{"light.a":{"+":{"a":{"brightness":10}}}}}"""))
        assertEquals("on", m["light.a"]!!.s)
        // one event with a, c and r
        applyEvent(m, JSONObject("""{"a":{"switch.b":{"s":"on","a":{}}},"c":{"light.a":{"+":{"s":"off"}}},"r":["camera.c"]}"""))
        assertEquals(setOf("light.a", "switch.b"), m.keys)
        assertEquals("off", m["light.a"]!!.s)
    }

    @Test fun home() {
        val m = ents("""{"a":{
            "light.lr":{"s":"on","a":{"friendly_name":"Living Room Lights"}},
            "light.lr2":{"s":"on","a":{"friendly_name":"living room"}},
            "switch.dev":{"s":"off","a":{"friendly_name":"Kettle"}},
            "fan.hidden":{"s":"off","a":{"friendly_name":"Hidden"}},
            "switch.cfg":{"s":"off","a":{"friendly_name":"Config"}},
            "lock.door":{"s":"locked","a":{"friendly_name":"Door"}},
            "cover.nobody":{"s":"open","a":{}},
            "scene.night":{"s":"unknown","a":{"friendly_name":"Night"}},
            "script.lr":{"s":"off","a":{"friendly_name":"Movie"}},
            "sensor.x":{"s":"1","a":{}},
            "camera.cam":{"s":"idle","a":{"friendly_name":"Cam"}}}}""")
        val reg = parseEntityReg(JSONObject("""{"entities":[
            {"ei":"light.lr","ai":"living_room"},{"ei":"light.lr2","ai":"living_room"},{"ei":"switch.dev","di":"d1"},
            {"ei":"fan.hidden","hb":true,"ai":"kitchen"},{"ei":"switch.cfg","ec":0,"ai":"kitchen"},
            {"ei":"lock.door","di":"d2"},{"ei":"script.lr","ai":"living_room"}],"entity_categories":{"0":"config","1":"diagnostic"}}"""))
        val dev = parseDevices(JSONArray("""[{"id":"d1","area_id":"kitchen"},{"id":"d2","area_id":null}]"""))
        val areas = parseAreas(JSONArray("""[{"area_id":"kitchen","name":"Kitchen"},{"area_id":"living_room","name":"Living Room"},{"area_id":"empty","name":"Empty"}]"""))
        val home = buildHome(m, reg, dev, areas)
        assertEquals(listOf("Scenes", "Kitchen", "Living Room", "Other"), home.map { it.title })
        assertEquals(listOf("scenes", "area:kitchen", "area:living_room", "other"), home.map { it.key })
        assertEquals("Living Room Lights", home[2].tiles[0].full)
        assertEquals(listOf("Night"), home[0].tiles.map { it.name })
        assertEquals(listOf("switch.dev"), home[1].tiles.map { it.id }) // via device; hidden + config skipped
        assertEquals(listOf("Lights", "living room", "Movie"), home[2].tiles.map { it.name }) // prefix stripped only when something is left
        assertEquals(listOf("cover.nobody", "lock.door"), home[3].tiles.map { it.id }) // name falls back to the id; sorted by name
        assertEquals(listOf("camera.cam"), buildCameras(m, reg).map { it.id })
    }

    @Test fun readings() {
        val m = ents("""{"a":{
            "sensor.temp":{"s":"21.46","a":{"friendly_name":"Kitchen Temperature","unit_of_measurement":"°C"}},
            "sensor.nowhere":{"s":"5","a":{"friendly_name":"Nowhere"}},
            "sensor.dead":{"s":"unavailable","a":{"friendly_name":"Dead"}},
            "sensor.unknown":{"s":"unknown","a":{"friendly_name":"Unknown"}},
            "sensor.dawn":{"s":"2026-11-26T22:24:47+00:00","a":{"friendly_name":"Dawn","device_class":"timestamp"}},
            "binary_sensor.door":{"s":"on","a":{"friendly_name":"A door","device_class":"door"}},
            "select.mode":{"s":"fast","a":{"friendly_name":"Mode"}},
            "switch.z":{"s":"off","a":{"friendly_name":"Zz switch"}},
            "climate.ac":{"s":"cool","a":{"friendly_name":"Air"}},
            "media_player.tv":{"s":"off","a":{"friendly_name":"TV"}},
            "sensor.nowhere_dead":{"s":"unavailable","a":{}}}}""")
        val reg = parseEntityReg(JSONObject("""{"entities":[
            {"ei":"sensor.temp","ai":"k","dp":1},{"ei":"sensor.dead","ai":"k"},{"ei":"sensor.unknown","ai":"k"},{"ei":"sensor.dawn","ai":"k"},
            {"ei":"binary_sensor.door","ai":"k"},{"ei":"select.mode","ai":"k"},{"ei":"switch.z","ai":"k"},{"ei":"climate.ac","ai":"k"}]}"""))
        val home = buildHome(m, reg, emptyMap(), listOf("k" to "Kitchen"))
        assertEquals(listOf("Kitchen", "Other"), home.map { it.title })
        // controls first (by name), then readings (by name); unavailable, unknown and timestamp readings skipped
        assertEquals(listOf("climate.ac", "switch.z", "binary_sensor.door", "select.mode", "sensor.temp"), home[0].tiles.map { it.id })
        assertEquals(Tile("sensor.temp", "Temperature", 1, "Kitchen Temperature"), home[0].tiles.last())
        assertEquals(listOf("media_player.tv"), home[1].tiles.map { it.id }) // area-less readings never go to Other
    }

    @Test fun ptz() {
        val reg = parseEntityReg(JSONObject("""{"entities":[
            {"ei":"camera.own","pl":"onvif"},
            {"ei":"camera.front","pl":"generic","ai":"front"},{"ei":"camera.front_onvif","pl":"onvif","ai":"front","hb":true},
            {"ei":"camera.yard1","pl":"generic","di":"d1"},{"ei":"camera.yard2","pl":"generic","ai":"yard"},{"ei":"camera.yard_onvif","pl":"onvif","ai":"yard","hb":true},
            {"ei":"camera.hall","pl":"generic","ai":"hall"},{"ei":"camera.hall_other","pl":"generic","ai":"hall","hb":true}]}"""))
        val dev = mapOf("d1" to "yard")
        val areas = listOf("front" to "Front", "yard" to "Yard", "hall" to "Hall")
        val m = ents("""{"a":{${reg.keys.joinToString(",") { "\"$it\":{\"s\":\"idle\",\"a\":{}}" }}}}""")
        val cams = buildCameras(m, reg)
        assertEquals(listOf("camera.front", "camera.hall", "camera.own", "camera.yard1", "camera.yard2"), cams.map { it.id }) // hidden ones not shown
        // own onvif; the only shown camera in an area with a hidden onvif one; two shown cameras in that area → none; hidden non-onvif → none
        assertEquals(mapOf("camera.own" to "camera.own", "camera.front" to "camera.front_onvif"), ptzTargets(cams, reg, dev, areas))
    }

    @Test fun taps() {
        assertEquals("toggle", tapAction("valve", "open", 0))
        assertEquals(SHEET, tapAction("climate", "heat", 0))
        assertEquals(SHEET, tapAction("siren", "off", 3))
        assertEquals(MENU, tapAction("select", "a", 0))
        assertNull(tapAction("sensor", "1", 0))
        // vacuum
        assertEquals("pause", tapAction("vacuum", "cleaning", 4 or 8192))
        assertEquals("return_to_base", tapAction("vacuum", "cleaning", 16))
        assertEquals("start", tapAction("vacuum", "docked", 8192))
        assertEquals(SHEET, tapAction("vacuum", "docked", 4)) // can't start from a tap: the sheet instead
        // lawn mower
        assertEquals("pause", tapAction("lawn_mower", "mowing", 3))
        assertEquals("start_mowing", tapAction("lawn_mower", "docked", 1))
        // media player
        assertEquals("media_play_pause", tapAction("media_player", "playing", 0))
        assertEquals("media_play_pause", tapAction("media_player", "paused", 0))
        assertEquals("turn_on", tapAction("media_player", "off", 128))
        assertEquals(SHEET, tapAction("media_player", "off", 0))
        assertEquals(SHEET, tapAction("media_player", "idle", 128))
        // alarm never acts
        for (s in listOf("disarmed", "armed_home", "armed_away", "triggered", "arming", "pending")) assertEquals(SHEET, tapAction("alarm_control_panel", s, 63))
        assertEquals("closed", optimistic("valve", "open"))
        assertEquals("open", optimistic("valve", "closed"))
        assertEquals("off", optimistic("remote", "on"))
        assertNull(optimistic("vacuum", "docked"))
        assertTrue(active("alarm_control_panel", "armed_night")); assertTrue(active("alarm_control_panel", "triggered"))
        assertFalse(active("alarm_control_panel", "disarmed")); assertFalse(active("binary_sensor", "on"))
        assertTrue(active("climate", "heat")); assertFalse(active("climate", "off"))
        assertTrue(active("valve", "opening")); assertTrue(active("vacuum", "cleaning")); assertFalse(active("media_player", "paused"))
    }

    @Test fun moreTexts() {
        fun t(d: String, s: String, a: String = "{}", dp: Int? = null) = stateText(d, s, JSONObject(a), dp)
        assertEquals("On", t("siren", "on"))
        assertEquals("Opening · 30%", t("valve", "opening", """{"current_position":30}"""))
        assertEquals("Heat · 21.5 °C", t("climate", "heat", """{"current_temperature":21.5,"temperature_unit":"°C"}"""))
        assertEquals("Off · 19 °C", t("climate", "off", """{"current_temperature":19.0,"temperature_unit":"°C"}"""))
        assertEquals("Heat cool", t("climate", "heat_cool", """{"current_temperature":null}"""))
        assertEquals("Heat pump · 48.3 °C", t("water_heater", "heat_pump", """{"operation_mode":"heat_pump","temperature":48.3,"temperature_unit":"°C"}"""))
        assertEquals("On · 65%", t("humidifier", "on", """{"humidity":65}""")); assertEquals("Off", t("humidifier", "off", """{"humidity":65}"""))
        assertEquals("Song", t("media_player", "paused", """{"media_title":"Song"}"""))
        assertEquals("Standby", t("media_player", "standby", """{"media_title":"Song"}"""))
        assertEquals("Docked", t("vacuum", "docked")); assertEquals("Mowing", t("lawn_mower", "mowing"))
        assertEquals("Armed home", t("alarm_control_panel", "armed_home")); assertEquals("Armed custom", t("alarm_control_panel", "armed_custom_bypass"))
        assertEquals("42 %", t("number", "42.0", """{"unit_of_measurement":"%"}""")); assertEquals("0.42", t("number", "0.42"))
        assertEquals("ridiculous_speed", t("select", "ridiculous_speed"))
        assertEquals("21.5 °C", t("sensor", "21.46", """{"unit_of_measurement":"°C"}""", 1))
        assertEquals("100 W", t("sensor", "99.6", """{"unit_of_measurement":"W"}""", 0))
        assertEquals("21.46 °C", t("sensor", "21.46", """{"unit_of_measurement":"°C"}"""))
        assertEquals("eco", t("sensor", "eco"))
        assertEquals("Open", t("binary_sensor", "on", """{"device_class":"garage_door"}"""))
        assertEquals("Clear", t("binary_sensor", "off", """{"device_class":"motion"}"""))
        assertEquals("Wet", t("binary_sensor", "on", """{"device_class":"moisture"}"""))
        assertEquals("OK", t("binary_sensor", "off", """{"device_class":"smoke"}"""))
        assertEquals("Disconnected", t("binary_sensor", "off", """{"device_class":"connectivity"}"""))
        assertEquals("On", t("binary_sensor", "on", """{"device_class":"battery_charging"}"""))
        assertEquals("Partly cloudy · 21.6 °C", t("weather", "partlycloudy", """{"temperature":21.6,"temperature_unit":"°C"}"""))
        assertEquals("Clear night", t("weather", "clear-night"))
        assertEquals("Sunny", t("weather", "sunny")); assertEquals("Lightning rainy", t("weather", "lightning-rainy"))
        assertEquals(0.42, snap(0.4213, 0.01), 0.0)
        assertEquals(21.5, snap(21.3, 0.5), 0.0)
        assertEquals(7.0, snap(6.6, 1.0, 1.0), 0.0)
    }

    @Test fun lock() {
        assertEquals("unlock" to true, lockTap("locked"))
        assertEquals("lock" to false, lockTap("unlocked"))
        assertEquals("lock" to false, lockTap("open"))
        assertEquals("lock" to false, lockTap("jammed"))
        assertNull(lockTap("locking")); assertNull(lockTap("unlocking")); assertNull(lockTap("opening"))
    }

    @Test fun refresh() {
        assertTrue(needsRefresh(null, Long.MAX_VALUE, 0))
        assertTrue(needsRefresh("t", 1_059_999, 1_000_000))
        assertFalse(needsRefresh("t", 1_060_000, 1_000_000))
    }

    @Test fun text() {
        assertEquals("On · 71%", stateText("light", "on", JSONObject("""{"brightness":180}""")))
        assertEquals("On", stateText("light", "on", JSONObject("""{"brightness":null}""")))
        assertEquals("Open · 70%", stateText("cover", "open", JSONObject("""{"current_position":70}""")))
        assertEquals("Unavailable", stateText("switch", "unknown", JSONObject()))
        assertEquals("Press", stateText("button", "unknown", JSONObject()))
        assertEquals(listOf("https://ha.local:8123", "http://ha.local:8123"), candidates(" ha.local:8123/ "))
        assertEquals(listOf("http://10.0.2.2:8124"), candidates("http://10.0.2.2:8124/"))
    }
}

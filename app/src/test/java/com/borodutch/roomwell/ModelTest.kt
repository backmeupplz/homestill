package com.borodutch.roomwell

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ModelTest {
    private fun ents(json: String) = mutableMapOf<String, Ent>().also { applyEvent(it, JSONObject(json)) }

    @Test fun addChangeRemove() {
        val m = ents("""{"a":{"light.a":{"s":"off","a":{"friendly_name":"A","brightness":null,"effect":"x"},"c":"1","lc":1},
            "sensor.t":{"s":"20","a":{}},"camera.c":{"s":"idle","a":{}}}}""")
        assertEquals(setOf("light.a", "camera.c"), m.keys) // other domains dropped
        val t = applyEvent(m, JSONObject("""{"c":{"light.a":{"+":{"s":"on","a":{"brightness":255},"lc":2},"-":{"a":["effect"]}},"sensor.t":{"+":{"s":"21"}}}}"""))
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
        assertEquals(listOf("Night"), home[0].tiles.map { it.name })
        assertEquals(listOf("switch.dev"), home[1].tiles.map { it.id }) // via device; hidden + config skipped
        assertEquals(listOf("Lights", "living room", "Movie"), home[2].tiles.map { it.name }) // prefix stripped only when something is left
        assertEquals(listOf("cover.nobody", "lock.door"), home[3].tiles.map { it.id }) // name falls back to the id; sorted by name
        assertEquals(listOf("camera.cam"), buildCameras(m, reg).map { it.id })
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

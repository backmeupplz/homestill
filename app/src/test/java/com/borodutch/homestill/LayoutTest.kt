package com.borodutch.homestill

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** SPEC "Customizing Home" test vectors. */
class LayoutTest {
    private val sections = listOf(
        Section("scenes", "Scenes", listOf(Tile("scene.s", "S"))),
        Section("area:a", "A", listOf(Tile("light.a1", "One"), Tile("light.a2", "Two"), Tile("light.a4", "Four"), Tile("sensor.a3", "Three"))),
        Section("area:b", "B", listOf(Tile("light.b1", "Lamp", full = "B Lamp"))),
        Section("other", "Other", listOf(Tile("switch.o", "O"))),
    )

    private fun arr(layout: String?) = arrange(sections, layout?.let(::JSONObject))
    private fun titles(rooms: List<Room>) = rooms.map { it.title }
    private fun ids(rooms: List<Room>, key: String) = rooms.first { it.key == key }.tiles.map { it.t.id }
    private val defaultA = listOf("light.a1", "light.a2", "light.a4", "sensor.a3")

    @Test fun none() {
        val r = arr(null)
        assertEquals(listOf("Scenes", "A", "B", "Other"), titles(r))
        assertEquals(defaultA, ids(r, "area:a"))
        assertEquals(listOf("light.b1"), ids(r, "area:b"))
        assertEquals(listOf("switch.o"), ids(r, "other"))
        assertTrue(r.all { !it.hidden && it.tiles.none { s -> s.hidden || s.moved } })
        assertEquals(r, homeRooms(r))
        assertEquals(r, arr("{}"))
    }

    @Test fun order() = assertEquals(listOf("B", "Scenes", "A", "Other"), titles(arr("""{"order":["area:b"]}""")))

    @Test fun tileOrder() = assertEquals(listOf("light.a2", "light.a1", "light.a4", "sensor.a3"), ids(arr("""{"tiles":{"area:a":["light.a2","light.a1"]}}"""), "area:a"))

    @Test fun notCurrentTileIdKept() {
        val l = JSONObject("""{"tiles":{"area:a":["sensor.zz","light.a1"]}}""")
        assertEquals(defaultA, ids(arrange(sections, l), "area:a"))
        val saved = moveTile(l, sections, "light.a2", "area:a", 0) // Move up
        assertEquals(listOf("light.a2", "light.a1", "light.a4", "sensor.a3", "sensor.zz"), saved.getJSONObject("tiles").strings("area:a"))
        assertFalse(saved.getJSONObject("moved").has("light.a2"))
        assertEquals(listOf("light.a2", "light.a1", "light.a4", "sensor.a3"), ids(arrange(sections, saved), "area:a"))
    }

    @Test fun movedTile() {
        val r = arr("""{"moved":{"light.b1":"area:a"},"tiles":{"area:a":["light.a1","light.b1"]}}""")
        val a = r.first { it.key == "area:a" }.tiles
        assertEquals(listOf("light.a1", "light.b1", "light.a2", "light.a4", "sensor.a3"), a.map { it.t.id })
        assertEquals(Spot(Tile("light.b1", "B Lamp", full = "B Lamp"), hidden = false, moved = true), a[1])
        assertTrue(a.filter { it.t.id != "light.b1" }.none { it.moved })
        assertEquals(emptyList<String>(), ids(r, "area:b")) // the editor still lists B, with no tiles
        assertEquals(listOf("Scenes", "A", "Other"), titles(homeRooms(r))) // Home drops it
    }

    @Test fun movedToGoneRoom() {
        val a = arr("""{"moved":{"light.a1":"area:gone"}}""").first { it.key == "area:a" }.tiles
        assertEquals(defaultA, a.map { it.t.id })
        assertFalse(a[0].moved)
        assertEquals("One", a[0].t.name)
    }

    @Test fun hidden() {
        val r = arr("""{"hidden":["light.a2"],"hiddenRooms":["other"]}""")
        val home = homeRooms(r)
        assertEquals(listOf("Scenes", "A", "B"), titles(home))
        assertEquals(listOf("light.a1", "light.a4", "sensor.a3"), ids(home, "area:a"))
        assertTrue(r.first { it.key == "area:a" }.tiles.first { it.t.id == "light.a2" }.hidden)
        assertTrue(r.first { it.key == "other" }.hidden)
        assertEquals(4, r.size)
    }

    @Test fun notCurrentRoomKept() {
        val l = JSONObject("""{"order":["zz","area:a"]}""")
        assertEquals(listOf("A", "Scenes", "B", "Other"), titles(arrange(sections, l)))
        val saved = moveRoom(l, sections, "area:b", 0)
        assertEquals(listOf("area:b", "area:a", "scenes", "other", "zz"), saved.strings("order"))
    }

    @Test fun saveRules() {
        // moving a tile to another room, then back to its own section
        val there = moveTile(null, sections, "light.a1", "area:b", 0)
        assertEquals("area:b", there.getJSONObject("moved").getString("light.a1"))
        assertEquals(listOf("light.a1", "light.b1"), there.getJSONObject("tiles").strings("area:b"))
        assertEquals(listOf("light.a2", "light.a4", "sensor.a3"), ids(arrange(sections, there), "area:a"))
        val back = moveTile(there, sections, "light.a1", "area:a", 1)
        assertFalse(back.getJSONObject("moved").has("light.a1"))
        assertEquals(listOf("light.a2", "light.a1", "light.a4", "sensor.a3"), back.getJSONObject("tiles").strings("area:a"))
        // eye toggles add and remove
        val h = toggleHidden(JSONObject("""{"order":["area:b"]}"""), "hidden", "light.a2")
        assertEquals(listOf("light.a2"), h.strings("hidden"))
        assertEquals(listOf("area:b"), h.strings("order")) // the rest of the layout is kept
        assertEquals(emptyList<String>(), toggleHidden(h, "hidden", "light.a2").strings("hidden"))
        assertEquals(listOf("other"), toggleHidden(null, "hiddenRooms", "other").strings("hiddenRooms"))
    }

    @Test fun malformedLayoutIsIgnored() {
        val r = arr("""{"order":"x","tiles":[1],"moved":{"light.a1":5},"hidden":{"a":1},"hiddenRooms":null}""")
        assertEquals(arr(null), r)
        assertEquals(listOf("area:b", "scenes", "area:a", "other"), moveRoom(JSONObject("""{"order":"x"}"""), sections, "area:b", 0).strings("order"))
    }
}

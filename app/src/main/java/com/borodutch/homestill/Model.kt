package com.borodutch.homestill

import org.json.JSONArray
import org.json.JSONObject
import java.math.BigDecimal
import java.math.RoundingMode
import java.util.Locale

// Pure logic: no Android, no Compose state, so the unit tests run it on the JVM.

val CONTROLS = setOf("light", "switch", "input_boolean", "fan", "cover", "lock", "button", "input_button", "scene", "script", "siren", "remote", "valve",
    "climate", "water_heater", "humidifier", "media_player", "vacuum", "lawn_mower", "alarm_control_panel")
val READINGS = setOf("number", "input_number", "select", "input_select", "sensor", "binary_sensor", "weather") // only with an area and a state
val HOME_DOMAINS = CONTROLS + READINGS
val ACTION_DOMAINS = setOf("button", "input_button", "scene", "script") // state is a timestamp or `unknown` by design
val HS_MODES = setOf("hs", "rgb", "rgbw", "rgbww", "xy")
/** Domains whose tile opens the detail sheet on long-press (some also on tap). */
val SHEETS = setOf("light", "fan", "cover", "siren", "valve", "climate", "water_heater", "humidifier", "media_player", "vacuum", "lawn_mower",
    "alarm_control_panel", "number", "input_number")

fun domain(id: String) = id.substringBefore('.')
fun shown(id: String) = domain(id).let { it in HOME_DOMAINS || it == "camera" }

/** Android's org.json turns JSON null into "null"/NaN in opt*; the reference jar the tests use doesn't. Read through these. */
fun JSONObject.str(k: String): String? = if (isNull(k)) null else optString(k)
fun JSONObject.num(k: String): Double? = if (isNull(k)) null else optDouble(k).takeUnless { it.isNaN() }
fun JSONObject.strings(k: String): List<String> = optJSONArray(k)?.let { a -> List(a.length()) { a.optString(it) } } ?: emptyList()

/** One entity as the socket last told us: state + attributes. Immutable: a change replaces it in the map. */
class Ent(val s: String, val a: JSONObject)

/** Applies one `subscribe_entities` event (any mix of a/c/r) to [ents], keeping only shown domains; returns the ids it touched. */
fun applyEvent(ents: MutableMap<String, Ent>, ev: JSONObject): Set<String> {
    val touched = mutableSetOf<String>()
    ev.optJSONObject("a")?.let { a ->
        for (id in a.keys()) if (shown(id)) {
            val e = a.getJSONObject(id)
            ents[id] = Ent(e.optString("s"), e.optJSONObject("a") ?: JSONObject()); touched += id
        }
    }
    ev.optJSONObject("c")?.let { c ->
        for (id in c.keys()) {
            val old = ents[id] ?: continue
            val d = c.getJSONObject(id)
            val attrs = JSONObject(old.a.toString())
            var s = old.s
            d.optJSONObject("+")?.let { p ->
                if (p.has("s")) s = p.getString("s")
                p.optJSONObject("a")?.let { for (k in it.keys()) attrs.put(k, it.get(k)) }
            }
            d.optJSONObject("-")?.optJSONArray("a")?.let { for (i in 0 until it.length()) attrs.remove(it.getString(i)) }
            ents[id] = Ent(s, attrs); touched += id
        }
    }
    ev.optJSONArray("r")?.let { for (i in 0 until it.length()) it.getString(i).let { id -> if (ents.remove(id) != null) touched += id } }
    return touched
}

/** Entity registry entry: own area, device, whether to skip it (hidden, or config/diagnostic), platform, display precision. */
class Reg(val area: String?, val device: String?, val skip: Boolean, val hidden: Boolean = false, val pl: String? = null, val dp: Int? = null)

fun parseEntityReg(r: JSONObject): Map<String, Reg> {
    val list = r.getJSONArray("entities")
    return (0 until list.length()).associate { i ->
        val e = list.getJSONObject(i)
        val hidden = e.optBoolean("hb")
        e.getString("ei") to Reg(e.str("ai"), e.str("di"), hidden || (e.has("ec") && !e.isNull("ec")), hidden, e.str("pl"), e.num("dp")?.toInt())
    }
}

fun parseDevices(r: JSONArray): Map<String, String?> = (0 until r.length()).associate { r.getJSONObject(it).let { d -> d.getString("id") to d.str("area_id") } }
fun parseAreas(r: JSONArray): List<Pair<String, String>> = (0 until r.length()).map { r.getJSONObject(it).let { a -> a.getString("area_id") to a.getString("name") } }

/** [name] = shown in its own section (area prefix dropped), [full] = the friendly name, shown when moved to another room. [dp] = sensor display precision. */
data class Tile(val id: String, val name: String, val dp: Int? = null, val full: String = name)
/** [key] = `area:<area_id>`, `scenes` or `other`: identifies a room everywhere (layout, list keys). */
data class Section(val key: String, val title: String, val tiles: List<Tile>)

fun entName(id: String, e: Ent?) = e?.a?.str("friendly_name")?.takeIf { it.isNotBlank() } ?: id

/** "Living Room Lights" in Living Room → "Lights". */
fun stripArea(name: String, area: String?): String {
    if (area == null || !name.startsWith("$area ", ignoreCase = true)) return name
    return name.substring(area.length + 1).trim().ifEmpty { name }
}

/** Own area, else the device's; null when neither names a known area. */
fun areaOf(r: Reg?, devArea: Map<String, String?>, names: Map<String, String>) = (r?.area ?: r?.device?.let { devArea[it] })?.takeIf { it in names }

private val byName = compareBy<Tile, String>(String.CASE_INSENSITIVE_ORDER) { it.name }
private val controlsFirst = compareBy<Tile> { domain(it.id) in READINGS }.then(byName)

/** Home sections: unplaced scenes/scripts first, then areas in registry order, then "Other" (controls only). */
fun buildHome(ents: Map<String, Ent>, reg: Map<String, Reg>, devArea: Map<String, String?>, areas: List<Pair<String, String>>): List<Section> {
    val names = areas.toMap()
    val byArea = mutableMapOf<String?, MutableList<Tile>>()
    val scenes = mutableListOf<Tile>()
    for ((id, e) in ents) {
        val d = domain(id)
        val r = reg[id]
        if (d !in HOME_DOMAINS || r?.skip == true) continue
        val area = areaOf(r, devArea, names)
        if (d in READINGS && (area == null || unavailable(d, e.s) || (d == "sensor" && e.a.str("device_class") == "timestamp"))) continue
        val full = entName(id, e)
        val tile = Tile(id, stripArea(full, names[area]), r?.dp?.takeIf { d == "sensor" }, full)
        if (area == null && (d == "scene" || d == "script")) scenes += tile else byArea.getOrPut(area) { mutableListOf() } += tile
    }
    return buildList {
        if (scenes.isNotEmpty()) add(Section("scenes", "Scenes", scenes.sortedWith(byName)))
        for ((id, name) in areas) byArea[id]?.let { add(Section("area:$id", name, it.sortedWith(controlsFirst))) }
        byArea[null]?.let { add(Section("other", "Other", it.sortedWith(byName))) }
    }
}

// ---- Home layout (SPEC "Customizing Home"): only the user's changes, applied on top of the sections ----

/** A tile as placed by the layout; a moved tile's [t] carries its full name. */
data class Spot(val t: Tile, val hidden: Boolean, val moved: Boolean)
data class Room(val key: String, val title: String, val hidden: Boolean, val tiles: List<Spot>)

/** The sections with the layout applied; every room and tile, hidden ones flagged. Never throws on a malformed layout. */
fun arrange(sections: List<Section>, layout: JSONObject?): List<Room> {
    val l = layout ?: JSONObject()
    val keys = sections.map { it.key }.toSet()
    val moved = l.optJSONObject("moved")
    val tiles = l.optJSONObject("tiles")
    val hidden = l.strings("hidden").toSet()
    val hiddenRooms = l.strings("hiddenRooms").toSet()
    // (tile, own section key) in default order, each with the room it lands in (rule 1)
    val all = sections.flatMap { s -> s.tiles.map { Triple(it, s.key, moved?.str(it.id)?.takeIf { k -> k in keys } ?: s.key) } }
    val order = l.strings("order").filter { it in keys }.distinct()
    return (order + sections.map { it.key }.filter { it !in order }).map { k ->
        val here = all.filter { it.third == k }
        val pinned = tiles?.strings(k).orEmpty().distinct().mapNotNull { id -> here.firstOrNull { it.first.id == id } }
        Room(k, sections.first { it.key == k }.title, k in hiddenRooms, (pinned + (here - pinned.toSet())).map { (t, own) ->
            Spot(if (own != k) t.copy(name = t.full) else t, t.id in hidden, own != k)
        })
    }
}

/** What Home draws: rooms not hidden, with their tiles not hidden; a room left empty is dropped. */
fun homeRooms(rooms: List<Room>) = rooms.filter { !it.hidden }.map { r -> r.copy(tiles = r.tiles.filter { !it.hidden }) }.filter { it.tiles.isNotEmpty() }

private fun copy(l: JSONObject?) = if (l == null) JSONObject() else JSONObject(l.toString())

/** Saves tile [id] at [index] in room [to] (also a move within its room). Ids in the old `tiles[to]` that are not current stay at the end. */
fun moveTile(layout: JSONObject?, sections: List<Section>, id: String, to: String, index: Int): JSONObject {
    val l = copy(layout)
    val own = sections.firstOrNull { s -> s.tiles.any { it.id == id } }?.key ?: return l
    val current = sections.flatMap { s -> s.tiles.map { it.id } }.toSet()
    val ids = arrange(sections, l).firstOrNull { it.key == to }?.tiles?.map { it.t.id }.orEmpty().filter { it != id }.toMutableList()
    ids.add(index.coerceIn(0, ids.size), id)
    val tiles = l.optJSONObject("tiles") ?: JSONObject()
    tiles.put(to, JSONArray(ids + tiles.strings(to).filter { it !in current }))
    l.put("tiles", tiles)
    val moved = l.optJSONObject("moved") ?: JSONObject()
    if (to == own) moved.remove(id) else moved.put(id, to)
    l.put("moved", moved)
    return l
}

/** Saves room [key] at [index]: `order` = every current room key in the new order, then the old keys that are not current. */
fun moveRoom(layout: JSONObject?, sections: List<Section>, key: String, index: Int): JSONObject {
    val l = copy(layout)
    val keys = arrange(sections, l).map { it.key }.filter { it != key }.toMutableList()
    keys.add(index.coerceIn(0, keys.size), key)
    val current = sections.map { it.key }.toSet()
    return l.put("order", JSONArray(keys + l.strings("order").filter { it !in current }))
}

/** The eye toggle: adds [id] to (or removes it from) [field], `hidden` or `hiddenRooms`. */
fun toggleHidden(layout: JSONObject?, field: String, id: String): JSONObject {
    val l = copy(layout)
    val list = l.strings(field)
    return l.put(field, JSONArray(if (id in list) list.filter { it != id } else list + id))
}

fun buildCameras(ents: Map<String, Ent>, reg: Map<String, Reg>): List<Tile> =
    ents.filter { (id, _) -> domain(id) == "camera" && reg[id]?.skip != true }.map { (id, e) -> Tile(id, entName(id, e)) }.sortedWith(byName)

/** Shown camera → the `onvif` camera entity that pans/tilts it: itself when its platform is onvif, else a hidden onvif camera in its
 *  area when it is the only shown camera there. */
fun ptzTargets(cams: List<Tile>, reg: Map<String, Reg>, devArea: Map<String, String?>, areas: List<Pair<String, String>>): Map<String, String> {
    val names = areas.toMap()
    val area = cams.associate { it.id to areaOf(reg[it.id], devArea, names) }
    // several in one area: the lowest entity id (toMap keeps the last)
    val hiddenOnvif = reg.filter { (id, r) -> domain(id) == "camera" && r.hidden && r.pl == "onvif" }.mapNotNull { (id, r) -> areaOf(r, devArea, names)?.let { it to id } }
        .sortedByDescending { it.second }.toMap()
    return cams.mapNotNull { c ->
        val a = area[c.id]
        when {
            reg[c.id]?.pl == "onvif" -> c.id
            a != null && area.values.count { it == a } == 1 -> hiddenOnvif[a]
            else -> null
        }?.let { c.id to it }
    }.toMap()
}

/** A lock tap: the service and whether it needs a confirm first; null = no-op (moving). */
fun lockTap(s: String): Pair<String, Boolean>? = when (s) {
    "locked" -> "unlock" to true
    "unlocked", "open", "jammed" -> "lock" to false
    else -> null
}

const val SHEET = ":sheet"
const val MENU = ":menu"

/** What a tap does (locks aside, see [lockTap]): a service of the tile's domain, [SHEET], [MENU], or null = nothing. */
fun tapAction(d: String, s: String, f: Int): String? = when (d) {
    "light", "switch", "input_boolean", "fan", "cover", "remote", "valve", "humidifier" -> "toggle"
    "button", "input_button" -> "press"
    "scene", "script" -> "turn_on"
    "siren", "climate", "water_heater", "alarm_control_panel", "number", "input_number" -> SHEET
    "select", "input_select" -> MENU
    "media_player" -> when {
        s == "playing" || s == "paused" -> "media_play_pause"
        s == "off" && f and 128 != 0 -> "turn_on"
        else -> SHEET
    }
    "vacuum" -> when {
        s == "cleaning" -> if (f and 4 != 0) "pause" else "return_to_base"
        f and 8192 != 0 -> "start"
        else -> SHEET
    }
    "lawn_mower" -> when {
        s == "mowing" -> if (f and 2 != 0) "pause" else SHEET
        f and 1 != 0 -> "start_mowing"
        else -> SHEET
    }
    else -> null
}

/** The state to show at once after a tap, before the server confirms it; null = no optimistic flip. */
fun optimistic(d: String, s: String): String? = when (d) {
    "light", "switch", "input_boolean", "fan", "remote", "humidifier" -> if (s == "on") "off" else "on"
    "cover" -> if (s == "open" || s == "opening") "closing" else "opening"
    "valve" -> if (s == "open" || s == "opening") "closed" else "open"
    "lock" -> lockTap(s)?.first?.let { it + "ing" }
    else -> null
}

/** The tile is tinted. */
fun active(d: String, s: String): Boolean = when (d) {
    "light", "switch", "input_boolean", "fan", "siren", "remote", "humidifier", "script" -> s == "on"
    "cover", "valve" -> s == "open" || s == "opening"
    "lock" -> s == "unlocked" || s == "unlocking" || s == "open"
    "climate", "water_heater" -> s != "off" && !unavailable(d, s)
    "media_player" -> s == "playing"
    "vacuum" -> s == "cleaning"
    "lawn_mower" -> s == "mowing"
    "alarm_control_panel" -> s.startsWith("armed_") || s == "triggered"
    else -> false
}

fun needsRefresh(token: String?, expiresAt: Long, now: Long) = token == null || expiresAt - now < 60_000

fun unavailable(d: String, s: String) = s == "unavailable" || (s == "unknown" && d !in ACTION_DOMAINS)

/** "fan_only" → "Fan only". */
fun label(s: String) = s.replace('_', ' ').replaceFirstChar { it.uppercase() }

/** [v] moved onto the grid min + k·step, rounded to the step's decimals (0.42, not 0.42000000000000004). */
fun snap(v: Double, step: Double, min: Double = 0.0): Double {
    val x = min + Math.round((v - min) / step) * step
    return BigDecimal.valueOf(x).setScale(BigDecimal.valueOf(step).stripTrailingZeros().scale().coerceAtLeast(0), RoundingMode.HALF_UP).toDouble()
}

/** 19.0 → "19", 21.5 → "21.5". */
fun fmt(x: Double) = if (x == Math.rint(x) && Math.abs(x) < 1e15) x.toLong().toString() else x.toString()

private fun temp(a: JSONObject, k: String) = a.num(k)?.let { " · " + fmt(it) + (a.str("temperature_unit")?.let { u -> " $u" } ?: "") } ?: ""

private val BINARY = mapOf(
    listOf("door", "window", "opening", "garage_door") to ("Open" to "Closed"),
    listOf("motion", "occupancy", "presence") to ("Detected" to "Clear"),
    listOf("moisture") to ("Wet" to "Dry"),
    listOf("smoke", "gas", "carbon_monoxide", "problem", "safety", "tamper") to ("Detected" to "OK"),
    listOf("lock") to ("Unlocked" to "Locked"),
    listOf("battery") to ("Low" to "OK"),
    listOf("connectivity") to ("Connected" to "Disconnected"),
)

/** The one-line state under a tile's name (and under the sheet's title). [dp] = sensor display precision. */
fun stateText(d: String, s: String, a: JSONObject, dp: Int? = null): String {
    if (unavailable(d, s)) return "Unavailable"
    val cap = label(s)
    val unit = a.str("unit_of_measurement")?.takeIf { it.isNotEmpty() }?.let { " $it" } ?: ""
    return when (d) {
        "light" -> if (s == "on") a.num("brightness")?.let { "On · ${Math.round(it * 100 / 255)}%" } ?: "On" else cap
        "fan" -> if (s == "on") a.num("percentage")?.let { "On · ${Math.round(it)}%" } ?: "On" else cap
        "humidifier" -> if (s == "on") a.num("humidity")?.let { "On · ${fmt(it)}%" } ?: "On" else cap
        "cover", "valve" -> a.num("current_position")?.let { "$cap · ${Math.round(it)}%" } ?: cap
        "button", "input_button" -> "Press"
        "scene" -> "Activate"
        "script" -> if (s == "on") "Running" else "Run"
        "climate" -> cap + temp(a, "current_temperature")
        "water_heater" -> (a.str("operation_mode")?.let(::label) ?: cap) + temp(a, "temperature")
        "media_player" -> a.str("media_title")?.takeIf { (s == "playing" || s == "paused") && it.isNotBlank() } ?: cap
        "alarm_control_panel" -> if (s == "armed_custom_bypass") "Armed custom" else cap
        "number", "input_number" -> (s.toDoubleOrNull()?.let(::fmt) ?: s) + unit
        "select", "input_select" -> s
        "sensor" -> (s.toDoubleOrNull()?.takeIf { dp != null && it.isFinite() }?.let { String.format(Locale.US, "%.${dp}f", it) } ?: s) +
            (if (s.toDoubleOrNull() != null) unit else "")
        "binary_sensor" -> (BINARY.entries.firstOrNull { a.str("device_class") in it.key }?.value ?: ("On" to "Off")).let { if (s == "on") it.first else it.second }
        "weather" -> (if (s == "partlycloudy") "Partly cloudy" else label(s.replace('-', ' '))) + temp(a, "temperature")
        else -> cap
    }
}

/** URL as typed → base URLs to try, in order. */
fun candidates(input: String): List<String> {
    val u = input.trim().trimEnd('/')
    return if ("://" in u) listOf(u) else listOf("https://$u", "http://$u")
}

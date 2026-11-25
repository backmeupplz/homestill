package com.borodutch.roomwell

import org.json.JSONArray
import org.json.JSONObject

// Pure logic: no Android, no Compose state, so the unit tests run it on the JVM.

val HOME_DOMAINS = setOf("light", "switch", "input_boolean", "fan", "cover", "lock", "button", "input_button", "scene", "script")
val ACTION_DOMAINS = setOf("button", "input_button", "scene", "script") // state is a timestamp or `unknown` by design
val HS_MODES = setOf("hs", "rgb", "rgbw", "rgbww", "xy")

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

/** Entity registry entry: own area, device, and whether to skip it (hidden, or config/diagnostic). */
class Reg(val area: String?, val device: String?, val skip: Boolean)

fun parseEntityReg(r: JSONObject): Map<String, Reg> {
    val list = r.getJSONArray("entities")
    return (0 until list.length()).associate { i ->
        val e = list.getJSONObject(i)
        e.getString("ei") to Reg(e.str("ai"), e.str("di"), e.optBoolean("hb") || (e.has("ec") && !e.isNull("ec")))
    }
}

fun parseDevices(r: JSONArray): Map<String, String?> = (0 until r.length()).associate { r.getJSONObject(it).let { d -> d.getString("id") to d.str("area_id") } }
fun parseAreas(r: JSONArray): List<Pair<String, String>> = (0 until r.length()).map { r.getJSONObject(it).let { a -> a.getString("area_id") to a.getString("name") } }

data class Tile(val id: String, val name: String)
data class Section(val title: String, val tiles: List<Tile>)

fun entName(id: String, e: Ent?) = e?.a?.str("friendly_name")?.takeIf { it.isNotBlank() } ?: id

/** "Living Room Lights" in Living Room → "Lights". */
fun stripArea(name: String, area: String?): String {
    if (area == null || !name.startsWith("$area ", ignoreCase = true)) return name
    return name.substring(area.length + 1).trim().ifEmpty { name }
}

private val byName = compareBy<Tile, String>(String.CASE_INSENSITIVE_ORDER) { it.name }

/** Home sections: unplaced scenes/scripts first, then areas in registry order, then "Other". */
fun buildHome(ents: Map<String, Ent>, reg: Map<String, Reg>, devArea: Map<String, String?>, areas: List<Pair<String, String>>): List<Section> {
    val names = areas.toMap()
    val byArea = mutableMapOf<String?, MutableList<Tile>>()
    val scenes = mutableListOf<Tile>()
    for ((id, e) in ents) {
        val d = domain(id)
        val r = reg[id]
        if (d !in HOME_DOMAINS || r?.skip == true) continue
        val area = (r?.area ?: r?.device?.let { devArea[it] })?.takeIf { it in names }
        val tile = Tile(id, stripArea(entName(id, e), names[area]))
        if (area == null && (d == "scene" || d == "script")) scenes += tile else byArea.getOrPut(area) { mutableListOf() } += tile
    }
    return buildList {
        if (scenes.isNotEmpty()) add(Section("Scenes", scenes.sortedWith(byName)))
        for ((id, name) in areas) byArea[id]?.let { add(Section(name, it.sortedWith(byName))) }
        byArea[null]?.let { add(Section("Other", it.sortedWith(byName))) }
    }
}

fun buildCameras(ents: Map<String, Ent>, reg: Map<String, Reg>): List<Tile> =
    ents.filter { (id, _) -> domain(id) == "camera" && reg[id]?.skip != true }.map { (id, e) -> Tile(id, entName(id, e)) }.sortedWith(byName)

/** A lock tap: the service and whether it needs a confirm first; null = no-op (moving). */
fun lockTap(s: String): Pair<String, Boolean>? = when (s) {
    "locked" -> "unlock" to true
    "unlocked", "open", "jammed" -> "lock" to false
    else -> null
}

/** The state to show at once after a tap, before the server confirms it; null = no optimistic flip. */
fun optimistic(d: String, s: String): String? = when (d) {
    "light", "switch", "input_boolean", "fan" -> if (s == "on") "off" else "on"
    "cover" -> if (s == "open" || s == "opening") "closing" else "opening"
    "lock" -> lockTap(s)?.first?.let { it + "ing" }
    else -> null
}

fun needsRefresh(token: String?, expiresAt: Long, now: Long) = token == null || expiresAt - now < 60_000

fun unavailable(d: String, s: String) = s == "unavailable" || (s == "unknown" && d !in ACTION_DOMAINS)

fun stateText(d: String, s: String, a: JSONObject): String {
    if (unavailable(d, s)) return "Unavailable"
    val cap = s.replaceFirstChar { it.uppercase() }
    return when (d) {
        "light" -> if (s == "on") a.num("brightness")?.let { "On · ${Math.round(it * 100 / 255)}%" } ?: "On" else cap
        "fan" -> if (s == "on") a.num("percentage")?.let { "On · ${Math.round(it)}%" } ?: "On" else cap
        "cover" -> a.num("current_position")?.let { "$cap · ${Math.round(it)}%" } ?: cap
        "button", "input_button" -> "Press"
        "scene" -> "Activate"
        "script" -> if (s == "on") "Running" else "Run"
        else -> cap
    }
}

/** URL as typed → base URLs to try, in order. */
fun candidates(input: String): List<String> {
    val u = input.trim().trimEnd('/')
    return if ("://" in u) listOf(u) else listOf("https://$u", "http://$u")
}

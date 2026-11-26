@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)

package com.borodutch.homestill

import android.os.Build
import android.os.SystemClock
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.IntSize
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

@Composable
fun HomestillTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val ctx = LocalContext.current
    val scheme = when {
        Build.VERSION.SDK_INT >= 31 -> if (dark) dynamicDarkColorScheme(ctx) else dynamicLightColorScheme(ctx)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = scheme, content = content)
}

@Composable
fun Root() {
    if (Ha.base == null) { SignIn(); return }
    var settings by remember { mutableStateOf(false) }
    var cameras by remember { mutableStateOf(false) }
    var full by remember { mutableStateOf<String?>(null) }
    val camTab = cameras && Ha.cams.isNotEmpty()
    when {
        full != null -> { BackHandler { full = null }; FullCamera(full!!) { full = null } }
        settings -> { BackHandler { settings = false }; Settings { settings = false } }
        else -> Scaffold(
            topBar = {
                Column {
                    TopAppBar(title = { Text(if (camTab) "Cameras" else "Home") }, actions = { IconButton({ settings = true }) { Icon(Ic.Settings, "Settings") } })
                    Banner()
                }
            },
            bottomBar = {
                if (Ha.cams.isNotEmpty()) NavigationBar {
                    NavigationBarItem(!camTab, { cameras = false }, { Icon(Ic.Home, null) }, label = { Text("Home") })
                    NavigationBarItem(camTab, { cameras = true }, { Icon(Ic.Camera, null) }, label = { Text("Cameras") })
                }
            },
        ) { pad ->
            Box(Modifier.padding(pad)) { if (camTab) CamerasScreen { full = it } else HomeScreen() }
        }
    }
}

@Composable
fun Banner() {
    if (Ha.status == Status.Live) return
    Surface(color = MaterialTheme.colorScheme.secondaryContainer, modifier = Modifier.fillMaxWidth().clickable { Ha.connectNow() }) {
        Text(if (Ha.status == Status.Connecting) "Connecting…" else "Can't reach Home Assistant", Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
            style = MaterialTheme.typography.labelMedium)
    }
}

@Composable
fun SignIn() {
    val scope = rememberCoroutineScope()
    var server by rememberSaveable { mutableStateOf("") }
    var user by rememberSaveable { mutableStateOf("") }
    var pass by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf(Ha.notice) }
    fun go() {
        if (busy) return
        busy = true; error = null
        scope.launch { try { Ha.login(server, user, pass, code) } catch (e: Msg) { error = e.message }; busy = false }
    }
    Column(
        Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).systemBarsPadding().imePadding().verticalScroll(rememberScrollState()).padding(28.dp),
        verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(Ic.Home, null, Modifier.size(56.dp), tint = MaterialTheme.colorScheme.primary)
        Text("Homestill", style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(top = 8.dp, bottom = 28.dp))
        val go = KeyboardActions(onGo = { go() })
        if (Ha.mfa) {
            OutlinedTextField(code, { code = it }, Modifier.fillMaxWidth(), label = { Text("Code") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Go), keyboardActions = go)
        } else {
            OutlinedTextField(server, { server = it }, Modifier.fillMaxWidth(), label = { Text("Server URL") }, singleLine = true,
                placeholder = { Text("http://homeassistant.local:8123") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Next))
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(user, { user = it }, Modifier.fillMaxWidth(), label = { Text("Username") }, singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next))
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(pass, { pass = it }, Modifier.fillMaxWidth(), label = { Text("Password") }, singleLine = true, visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Go), keyboardActions = go)
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 12.dp)) }
        Spacer(Modifier.height(24.dp))
        Button(::go, Modifier.fillMaxWidth().height(52.dp), enabled = !busy) {
            if (busy) CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.5.dp, color = LocalContentColor.current) else Text("Sign in")
        }
    }
}

@Composable
fun HomeScreen() {
    var sheet by remember { mutableStateOf<Tile?>(null) }
    var confirm by remember { mutableStateOf<Tile?>(null) }
    val live = Ha.status == Status.Live
    if (Ha.sections.isEmpty() && live) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("No devices to show", color = MaterialTheme.colorScheme.onSurfaceVariant) }
    LazyVerticalGrid(GridCells.Fixed(2), Modifier.fillMaxSize().alpha(if (live) 1f else 0.6f), contentPadding = PaddingValues(12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        for ((i, s) in Ha.sections.withIndex()) {
            item(key = "h:$i", span = { GridItemSpan(maxLineSpan) }) {
                Text(s.title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(start = 4.dp, top = 10.dp))
            }
            items(s.tiles, key = { "$i:" + it.id }) { t -> EntityTile(t, live, { sheet = t }, { confirm = t }) }
        }
    }
    // fully open at once: the color wheel would sit below a half-open sheet
    sheet?.let { t -> ModalBottomSheet({ sheet = null }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) { Detail(t) } }
    confirm?.let { t ->
        AlertDialog({ confirm = null }, title = { Text("Unlock ${t.name}?") },
            confirmButton = { TextButton({ Ha.call("lock", "unlock", t.id, flip = "unlocking"); confirm = null }, colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text("Unlock") } },
            dismissButton = { TextButton({ confirm = null }) { Text("Cancel") } })
    }
}

private val Amber = Color(0xFFFFB300)

/** The light's own color; near-white (or none) → amber, so the tint stays visible on a light theme. */
fun lightColor(a: JSONObject): Color = a.optJSONArray("rgb_color")?.takeIf { it.length() == 3 && (0..2).any { i -> it.optInt(i) < 200 } }
    ?.let { Color(it.optInt(0), it.optInt(1), it.optInt(2)) } ?: Amber

@Composable
fun EntityTile(t: Tile, live: Boolean, onSheet: () -> Unit, onConfirm: () -> Unit) {
    val e = Ha.ents[t.id] ?: return
    val d = domain(t.id)
    val s = Ha.pending[t.id]?.s ?: e.s
    val off = unavailable(d, s)
    val on = !off && active(d, s)
    val accent = when {
        d == "light" -> lightColor(e.a)
        s == "triggered" -> MaterialTheme.colorScheme.error
        else -> MaterialTheme.colorScheme.primary
    }
    val tap = tapAction(d, s, e.a.optInt("supported_features"))
    var menu by remember { mutableStateOf(false) }
    val flash = remember { Animatable(0f) }
    val scope = rememberCoroutineScope()
    val base = MaterialTheme.colorScheme.surfaceContainerHigh
    Box {
        Column(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp))
                .background(if (on) accent.copy(alpha = 0.22f).compositeOver(base) else base)
                .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.35f * flash.value))
                .alpha(if (off) 0.45f else 1f)
                .combinedClickable(enabled = live && !off && (d == "lock" || tap != null || d in SHEETS), onLongClick = if (d in SHEETS) onSheet else null) {
                    when {
                        d == "lock" -> lockTap(s)?.let { (svc, ask) -> if (ask) onConfirm() else Ha.call("lock", svc, t.id, flip = optimistic(d, s)) }
                        tap == SHEET -> onSheet()
                        tap == MENU -> menu = true
                        tap != null -> Ha.call(d, tap, t.id, flip = optimistic(d, s))
                    }
                    if (d in ACTION_DOMAINS) scope.launch { flash.snapTo(1f); flash.animateTo(0f, tween(700)) }
                }
                .padding(14.dp),
        ) {
            Icon(icon(d, s, e.a), null, tint = if (on) accent else MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(10.dp))
            Text(t.name, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(stateText(d, s, e.a, t.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1,
                overflow = TextOverflow.Ellipsis)
        }
        if (tap == MENU) DropdownMenu(menu, { menu = false }) {
            for (o in e.a.strings("options")) DropdownMenuItem({ Text(o) }, { menu = false; Ha.call(d, "select_option", t.id, JSONObject().put("option", o), flip = o) })
        }
    }
}

fun icon(d: String, s: String, a: JSONObject) = when (d) {
    "light" -> Ic.Bulb
    "fan" -> Ic.Fan
    "cover" -> Ic.Window
    "lock" -> if (s == "locked" || s == "locking") Ic.Lock else Ic.LockOpen
    "button", "input_button" -> Ic.Button
    "scene" -> Ic.Scene
    "script" -> Ic.Script
    "climate", "water_heater" -> Ic.Thermo
    "valve", "humidifier" -> Ic.Drop
    "media_player" -> Ic.Music
    "vacuum" -> Ic.Vacuum
    "lawn_mower" -> Ic.Grass
    "alarm_control_panel" -> Ic.Shield
    "siren" -> Ic.Bell
    "number", "input_number" -> Ic.Tune
    "select", "input_select" -> Ic.List
    "weather" -> Ic.Cloud
    "sensor", "binary_sensor" -> when (a.str("device_class")) {
        "temperature" -> Ic.Thermo
        "humidity", "moisture" -> Ic.Drop
        "door", "window", "opening", "garage_door" -> Ic.Window
        "lock" -> if (s == "on") Ic.LockOpen else Ic.Lock
        else -> if (d == "sensor") Ic.Chart else Ic.Button
    }
    else -> Ic.Power
}

/** The detail sheet ([SHEETS]): a header (name, state, on/off switch where there is one) and rows built from a few control kinds. */
@Composable
fun Detail(t: Tile) {
    val e = Ha.ents[t.id] ?: return
    val d = domain(t.id)
    val s = Ha.pending[t.id]?.s ?: e.s
    val a = e.a
    val f = a.optInt("supported_features")
    fun has(bit: Int) = f and bit != 0
    fun call(svc: String, data: JSONObject = JSONObject(), flip: String? = null) = Ha.call(d, svc, t.id, data, flip)
    val text = stateText(d, s, a, t.dp)
    val onOff = d in setOf("light", "fan", "siren", "humidifier")
    val power = when (d) {
        "water_heater" -> if (has(8)) s != "off" else null
        "media_player" -> if (has(128) || has(256)) s != "off" else null
        else -> if (onOff) s == "on" else null
    }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(start = 24.dp, end = 24.dp, bottom = 32.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(t.name, style = MaterialTheme.typography.titleLarge)
                Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant)
                val extra = when (d) {
                    "climate" -> listOfNotNull(a.str("hvac_action")?.let(::label))
                    "media_player" -> listOfNotNull(a.str("media_title")?.takeIf { it != text }, a.str("media_artist"))
                    else -> emptyList()
                }
                for (x in extra) Text(x, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
            }
            power?.let { p -> Switch(p, { call(if (it) "turn_on" else "turn_off", flip = if (onOff) (if (it) "on" else "off") else null) }) }
        }
        when (d) {
            "light" -> {
                val modes = e.a.strings("supported_color_modes")
                if (modes.any { it != "onoff" }) Ctl("Brightness", ((e.a.num("brightness") ?: 0.0) * 100 / 255).toFloat(), 1f..100f) {
                    Ha.call("light", "turn_on", t.id, JSONObject().put("brightness_pct", Math.round(it)))
                }
                if ("color_temp" in modes) {
                    val lo = e.a.num("min_color_temp_kelvin")?.toFloat() ?: 2000f
                    val hi = e.a.num("max_color_temp_kelvin")?.toFloat() ?: 6500f
                    Ctl("Warmth", e.a.num("color_temp_kelvin")?.toFloat() ?: hi, lo..hi, Warm) {
                        Ha.call("light", "turn_on", t.id, JSONObject().put("color_temp_kelvin", Math.round(it)))
                    }
                }
                if (modes.any { it in HS_MODES }) {
                    val hs = e.a.optJSONArray("hs_color")
                    Text("Color", style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(top = 20.dp, bottom = 8.dp))
                    Wheel(hs?.optDouble(0)?.toFloat()?.takeUnless { it.isNaN() } ?: 0f, hs?.optDouble(1)?.toFloat()?.takeUnless { it.isNaN() } ?: 0f) { h, sat ->
                        Ha.call("light", "turn_on", t.id, JSONObject().put("hs_color", JSONArray().put(Math.round(h)).put(Math.round(sat))))
                    }
                }
            }
            "fan" -> if (f and 1 != 0) Ctl("Speed", e.a.num("percentage")?.toFloat() ?: 0f, 0f..100f) {
                Ha.call("fan", "set_percentage", t.id, JSONObject().put("percentage", Math.round(it)))
            }
            "cover" -> {
                Row(Modifier.padding(top = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for ((label, svc) in listOf("Open" to "open_cover", "Stop" to "stop_cover", "Close" to "close_cover"))
                        FilledTonalButton({ Ha.call("cover", svc, t.id) }, Modifier.weight(1f)) { Text(label) }
                }
                if (f and 4 != 0) Ctl("Position", e.a.num("current_position")?.toFloat() ?: 0f, 0f..100f) {
                    Ha.call("cover", "set_cover_position", t.id, JSONObject().put("position", Math.round(it)))
                }
            }
            "valve" -> {
                Buttons(listOf("Open" to "open_valve", "Stop" to "stop_valve", "Close" to "close_valve").filterIndexed { i, _ -> has(intArrayOf(1, 8, 2)[i]) }) { call(it) }
                if (has(4)) Ctl("Position", a.num("current_position")?.toFloat() ?: 0f, 0f..100f) { call("set_valve_position", JSONObject().put("position", Math.round(it))) }
            }
            "climate" -> {
                val unit = a.str("temperature_unit")
                val step = a.num("target_temp_step") ?: if (unit == "°F") 1.0 else 0.5
                @Composable fun temp(label: String, k: String, send: (Double) -> Unit) = Stepper(label, a.num(k), a.num("min_temp"), a.num("max_temp"), step, unit, send)
                if (has(1) && s != "heat_cool") temp("Target", "temperature") { call("set_temperature", JSONObject().put("temperature", it)) }
                if (has(2) && s == "heat_cool") {
                    // both ends go in every call: remember what each stepper last sent until the server moves
                    val sent = remember { mutableMapOf<String, Double>() }
                    val lo = a.num("target_temp_low"); val hi = a.num("target_temp_high")
                    LaunchedEffect(lo, hi) { sent.clear() }
                    fun range(k: String, v: Double) {
                        sent[k] = v
                        call("set_temperature", JSONObject().put("target_temp_low", sent["target_temp_low"] ?: lo).put("target_temp_high", sent["target_temp_high"] ?: hi))
                    }
                    temp("Low", "target_temp_low") { range("target_temp_low", it) }
                    temp("High", "target_temp_high") { range("target_temp_high", it) }
                }
                Picker("Mode", s, a.strings("hvac_modes"), ::label) { call("set_hvac_mode", JSONObject().put("hvac_mode", it), flip = it) }
                if (has(16)) Picker("Preset", a.str("preset_mode"), a.strings("preset_modes")) { call("set_preset_mode", JSONObject().put("preset_mode", it)) }
                if (has(8)) Picker("Fan", a.str("fan_mode"), a.strings("fan_modes")) { call("set_fan_mode", JSONObject().put("fan_mode", it)) }
            }
            "water_heater" -> {
                val unit = a.str("temperature_unit")
                if (has(1)) Stepper("Target", a.num("temperature"), a.num("min_temp"), a.num("max_temp"), a.num("target_temp_step") ?: if (unit == "°F") 1.0 else 0.5, unit) {
                    call("set_temperature", JSONObject().put("temperature", it))
                }
                if (has(2)) Picker("Operation", a.str("operation_mode"), a.strings("operation_list"), ::label) { call("set_operation_mode", JSONObject().put("operation_mode", it)) }
                if (has(4)) SwitchRow("Away", a.str("away_mode") == "on") { call("set_away_mode", JSONObject().put("away_mode", it)) }
            }
            "humidifier" -> {
                val lo = a.num("min_humidity") ?: 0.0; val hi = a.num("max_humidity") ?: 100.0
                Ctl("Target humidity", (a.num("humidity") ?: lo).toFloat(), lo.toFloat()..hi.toFloat()) {
                    call("set_humidity", JSONObject().put("humidity", snap(it.toDouble(), a.num("target_humidity_step") ?: 1.0, lo)))
                }
                if (has(1)) Picker("Mode", a.str("mode"), a.strings("available_modes")) { call("set_mode", JSONObject().put("mode", it)) }
            }
            "media_player" -> {
                Buttons(listOfNotNull(("Previous" to "media_previous_track").takeIf { has(16) },
                    ((if (s == "playing") "Pause" else "Play") to "media_play_pause").takeIf { has(1) || has(16384) },
                    ("Next" to "media_next_track").takeIf { has(32) })) { call(it) }
                if (has(4)) Ctl("Volume", ((a.num("volume_level") ?: 0.0) * 100).toFloat(), 0f..100f) { call("volume_set", JSONObject().put("volume_level", Math.round(it) / 100.0)) }
                if (has(8)) SwitchRow("Mute", a.optBoolean("is_volume_muted")) { call("volume_mute", JSONObject().put("is_volume_muted", it)) }
                if (has(2048)) Picker("Source", a.str("source"), a.strings("source_list")) { call("select_source", JSONObject().put("source", it)) }
            }
            "vacuum" -> {
                Buttons(listOf("Start" to "start", "Pause" to "pause", "Return home" to "return_to_base", "Locate" to "locate").filterIndexed { i, _ -> has(intArrayOf(8192, 4, 16, 512)[i]) }) { call(it) }
                if (has(32)) Picker("Fan speed", a.str("fan_speed"), a.strings("fan_speed_list")) { call("set_fan_speed", JSONObject().put("fan_speed", it)) }
            }
            "lawn_mower" -> Buttons(listOf("Start" to "start_mowing", "Pause" to "pause", "Dock" to "dock").filterIndexed { i, _ -> has(intArrayOf(1, 2, 4)[i]) }) { call(it) }
            "alarm_control_panel" -> Alarm(t.name, s, a, f, ::call)
            "number", "input_number" -> {
                val lo = a.num("min") ?: 0.0; val hi = a.num("max") ?: 100.0
                Ctl("Value", (s.toDoubleOrNull() ?: lo).toFloat(), lo.toFloat()..hi.toFloat()) { call("set_value", JSONObject().put("value", snap(it.toDouble(), a.num("step") ?: 1.0, lo))) }
            }
        }
    }
}

/** Code field (never stored) + arm/disarm buttons. Disarm needs the code when there is a code format, else a confirm. */
@Composable
fun Alarm(name: String, s: String, a: JSONObject, f: Int, call: (String, JSONObject, String?) -> Unit) {
    var code by remember { mutableStateOf("") }
    var ask by remember { mutableStateOf(false) }
    val format = a.str("code_format")
    fun data() = JSONObject().apply { if (code.isNotEmpty()) put("code", code) }
    if (format != null) OutlinedTextField(code, { code = it }, Modifier.fillMaxWidth().padding(top = 16.dp), label = { Text("Code") }, singleLine = true,
        visualTransformation = PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(keyboardType = if (format == "number") KeyboardType.NumberPassword else KeyboardType.Password))
    val armOk = format == null || code.isNotEmpty() || !a.optBoolean("code_arm_required")
    Buttons(listOf("Arm home" to "alarm_arm_home", "Arm away" to "alarm_arm_away", "Arm night" to "alarm_arm_night", "Arm vacation" to "alarm_arm_vacation")
        .filterIndexed { i, _ -> f and intArrayOf(1, 2, 4, 32)[i] != 0 }, armOk) { call(it, data(), null); code = "" }
    if (s != "disarmed") Buttons(listOf("Disarm" to "alarm_disarm"), format == null || code.isNotEmpty()) { if (format == null) ask = true else { call(it, data(), null); code = "" } }
    if (ask) AlertDialog({ ask = false }, title = { Text("Disarm $name?") },
        confirmButton = { TextButton({ ask = false; call("alarm_disarm", JSONObject(), null) }, colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text("Disarm") } },
        dismissButton = { TextButton({ ask = false }) { Text("Cancel") } })
}

/** A row of tonal buttons: label → service. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun Buttons(items: List<Pair<String, String>>, enabled: Boolean = true, onClick: (String) -> Unit) {
    if (items.isEmpty()) return
    FlowRow(Modifier.fillMaxWidth().padding(top = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for ((label, svc) in items) FilledTonalButton({ onClick(svc) }, enabled = enabled) { Text(label) }
    }
}

@Composable
fun SwitchRow(label: String, on: Boolean, set: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.labelLarge)
        Switch(on, set)
    }
}

/** − value +: sends 600 ms after the last press, then follows the server again. */
@Composable
fun Stepper(label: String, server: Double?, min: Double?, max: Double?, step: Double, unit: String?, send: (Double) -> Unit) {
    if (server == null || min == null || max == null || min >= max) return // SPEC: no target or bounds → no stepper
    var v by remember { mutableStateOf<Double?>(null) }
    var presses by remember { mutableIntStateOf(0) }
    var pending by remember { mutableStateOf(false) }
    val latest by rememberUpdatedState(send) // the low/high pair reads the other end at send time
    LaunchedEffect(server) { v = null }
    LaunchedEffect(presses) { if (presses > 0) { delay(600); pending = false; v?.let(latest) } }
    DisposableEffect(Unit) { onDispose { if (pending) v?.let(latest) } } // the sheet closed within 600 ms
    fun bump(dir: Int) {
        v = snap((v ?: server) + dir * step, step, min).coerceIn(min, max)
        pending = true; presses++
    }
    Row(Modifier.fillMaxWidth().padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.labelLarge)
        FilledTonalIconButton({ bump(-1) }) { Text("−", style = MaterialTheme.typography.titleLarge) }
        Text((v ?: server)?.let { fmt(it) + (unit?.let { u -> " $u" } ?: "") } ?: "—", Modifier.widthIn(min = 84.dp), textAlign = TextAlign.Center,
            style = MaterialTheme.typography.titleMedium)
        FilledTonalIconButton({ bump(1) }) { Text("+", style = MaterialTheme.typography.titleLarge) }
    }
}

/** A menu of strings that shows the current one. */
@Composable
fun Picker(label: String, current: String?, options: List<String>, show: (String) -> String = { it }, pick: (String) -> Unit) {
    if (options.isEmpty()) return
    var open by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.labelLarge)
        Box {
            OutlinedButton({ open = true }) { Text(current?.let(show) ?: "—") }
            DropdownMenu(open, { open = false }) { for (o in options) DropdownMenuItem({ Text(show(o)) }, { open = false; pick(o) }) }
        }
    }
}

/** A slider that sends on release and at most every 300 ms while dragging, then follows the server again. */
@Composable
fun Ctl(label: String, server: Float, range: ClosedFloatingPointRange<Float>, brush: Brush? = null, send: (Float) -> Unit) {
    var v by remember { mutableStateOf<Float?>(null) }
    var dragging by remember { mutableStateOf(false) }
    var last by remember { mutableLongStateOf(0L) }
    LaunchedEffect(server) { if (!dragging) v = null }
    Text(label, style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(top = 20.dp))
    Slider(v ?: server.coerceIn(range), {
        v = it; dragging = true
        val now = SystemClock.uptimeMillis()
        if (now - last >= 300) { last = now; send(it) }
    }, valueRange = range, onValueChangeFinished = { dragging = false; v?.let(send) },
        track = { if (brush == null) SliderDefaults.Track(it) else Box(Modifier.fillMaxWidth().height(16.dp).clip(CircleShape).background(brush)) })
}

/** Warm (low kelvin) on the left, cool on the right. */
private val Warm = Brush.horizontalGradient(listOf(Color(0xFFFFA24A), Color(0xFFFFF3E0), Color(0xFFCFDFFF)))
private val Hues = Brush.sweepGradient((0..6).map { Color.hsv(it * 60f, 1f, 1f) })

/** Hue/saturation wheel: angle = hue (clockwise from red at 3 o'clock), distance from the center = saturation. Sends like [Ctl]. */
@Composable
fun Wheel(hue: Float, sat: Float, send: (Float, Float) -> Unit) {
    var v by remember { mutableStateOf<Pair<Float, Float>?>(null) }
    var dragging by remember { mutableStateOf(false) }
    var last by remember { mutableLongStateOf(0L) }
    LaunchedEffect(hue, sat) { if (!dragging) v = null }
    fun pick(p: Offset, size: IntSize, now: Boolean) {
        val r = size.width / 2f
        val (dx, dy) = p - Offset(r, r)
        val hs = (Math.toDegrees(atan2(dy, dx).toDouble()).toFloat() + 360f) % 360f to (hypot(dx, dy) / r * 100f).coerceAtMost(100f)
        v = hs
        val t = SystemClock.uptimeMillis()
        if (now || t - last >= 300) { last = t; send(hs.first, hs.second) }
    }
    val (h, s) = v ?: (hue to sat.coerceIn(0f, 100f))
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(240.dp)
            .pointerInput(Unit) { detectTapGestures { pick(it, size, true) } }
            .pointerInput(Unit) {
                detectDragGestures(onDragStart = { dragging = true; pick(it, size, false) },
                    onDragEnd = { dragging = false; v?.let { send(it.first, it.second) } },
                    onDragCancel = { dragging = false }) { c, _ -> c.consume(); pick(c.position, size, false) }
            }) {
            drawCircle(Hues)
            drawCircle(Brush.radialGradient(listOf(Color.White, Color.White.copy(alpha = 0f))))
            val a = Math.toRadians(h.toDouble())
            val at = center + Offset(cos(a).toFloat(), sin(a).toFloat()) * (size.minDimension / 2 * s / 100f)
            drawCircle(Color.hsv(h, s / 100f, 1f), 14.dp.toPx(), at)
            drawCircle(Color.White, 14.dp.toPx(), at, style = Stroke(3.dp.toPx()))
            drawCircle(Color.Black.copy(alpha = 0.25f), 15.5.dp.toPx(), at, style = Stroke(1.dp.toPx()))
        }
    }
}

@Composable
fun Settings(onBack: () -> Unit) {
    val ctx = LocalContext.current
    val version = remember { ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName }
    Scaffold(topBar = { TopAppBar(title = { Text("Settings") }, navigationIcon = { IconButton(onBack) { Icon(Ic.Back, "Back") } }) }) { pad ->
        Column(Modifier.padding(pad)) {
            for ((k, v) in listOf("Server" to Ha.base.orEmpty(), "Signed in as" to Ha.user, "Version" to version.orEmpty()))
                ListItem(headlineContent = { Text(v) }, overlineContent = { Text(k) })
            val uri = LocalUriHandler.current
            TextButton({ uri.openUri("https://homestill.app/privacy/") }, Modifier.padding(horizontal = 8.dp)) { Text("Privacy policy") }
            TextButton({ Ha.signOut() }, Modifier.padding(horizontal = 8.dp), colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text("Sign out") }
        }
    }
}

private fun vec(name: String, path: String) = ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f)
    .addPath(PathParser().parsePathString(path).toNodes(), fill = SolidColor(Color.Black)).build()

/** The few Material glyphs we use, as path data, so the extended icon library stays out of the APK. */
object Ic {
    val Home by lazy { vec("home", "M10 20v-6h4v6h5v-8h3L12 3 2 12h3v8z") }
    val Camera by lazy { vec("camera", "M17 10.5V7c0-.55-.45-1-1-1H4c-.55 0-1 .45-1 1v10c0 .55.45 1 1 1h12c.55 0 1-.45 1-1v-3.5l4 4v-11l-4 4z") }
    val Settings by lazy { vec("settings", "M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z") }
    val Back by lazy { vec("back", "M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z") }
    val Close by lazy { vec("close", "M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z") }
    val Bulb by lazy { vec("bulb", "M9 21c0 .55.45 1 1 1h4c.55 0 1-.45 1-1v-1H9v1zm3-19C8.14 2 5 5.14 5 9c0 2.38 1.19 4.47 3 5.74V17c0 .55.45 1 1 1h6c.55 0 1-.45 1-1v-2.26c1.81-1.27 3-3.36 3-5.74 0-3.86-3.14-7-7-7z") }
    val Power by lazy { vec("power", "M13 3h-2v10h2V3zm4.83 2.17l-1.42 1.42C17.99 7.86 19 9.81 19 12c0 3.87-3.13 7-7 7s-7-3.13-7-7c0-2.19 1.01-4.14 2.58-5.42L6.17 5.17C4.23 6.82 3 9.26 3 12c0 4.97 4.03 9 9 9s9-4.03 9-9c0-2.74-1.23-5.18-3.17-6.83z") }
    val Fan by lazy { vec("fan", "M14.5 17c0 1.65-1.35 3-3 3s-3-1.35-3-3h2c0 .55.45 1 1 1s1-.45 1-1-.45-1-1-1H2v-2h9.5c1.65 0 3 1.35 3 3zM19 6.5C19 4.57 17.43 3 15.5 3S12 4.57 12 6.5h2c0-.83.67-1.5 1.5-1.5s1.5.67 1.5 1.5S16.33 8 15.5 8H2v2h13.5c1.93 0 3.5-1.57 3.5-3.5zm-.5 4.5H2v2h16.5c.83 0 1.5.67 1.5 1.5s-.67 1.5-1.5 1.5v2c1.93 0 3.5-1.57 3.5-3.5S20.43 11 18.5 11z") }
    val Window by lazy { vec("window", "M4 3h16v18H4zM6 5v6h5V5zm7 0v6h5V5zM6 13v6h5v-6zm7 0v6h5v-6z") }
    val Lock by lazy { vec("lock", "M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z") }
    val LockOpen by lazy { vec("lockopen", "M12 17c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm6-9h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6h1.9c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm0 12H6V10h12v10z") }
    val Button by lazy { vec("button", "M12 7c-2.76 0-5 2.24-5 5s2.24 5 5 5 5-2.24 5-5-2.24-5-5-5zm0-5C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8z") }
    val Scene by lazy { vec("scene", "M19 9l1.25-2.75L23 5l-2.75-1.25L19 1l-1.25 2.75L15 5l2.75 1.25L19 9zm-7.5.5L9 4 6.5 9.5 1 12l5.5 2.5L9 20l2.5-5.5L17 12l-5.5-2.5zM19 15l-1.25 2.75L15 19l2.75 1.25L19 23l1.25-2.75L23 19l-2.75-1.25L19 15z") }
    val Thermo by lazy { vec("thermo", "M15 13V5c0-1.66-1.34-3-3-3S9 3.34 9 5v8c-1.21.91-2 2.37-2 4 0 2.76 2.24 5 5 5s5-2.24 5-5c0-1.63-.79-3.09-2-4z") }
    val Drop by lazy { vec("drop", "M12 2c-5.33 4.55-8 8.48-8 11.8 0 4.98 3.8 8.2 8 8.2s8-3.22 8-8.2c0-3.32-2.67-7.25-8-11.8z") }
    val Music by lazy { vec("music", "M12 3v10.55c-.59-.34-1.27-.55-2-.55-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4V7h4V3h-6z") }
    val Shield by lazy { vec("shield", "M12 1L3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4z") }
    val Bell by lazy { vec("bell", "M12 22c1.1 0 2-.9 2-2h-4c0 1.1.89 2 2 2zm6-6v-5c0-3.07-1.64-5.64-4.5-6.32V4c0-.83-.67-1.5-1.5-1.5s-1.5.67-1.5 1.5v.68C7.63 5.36 6 7.92 6 11v5l-2 2v1h16v-1l-2-2z") }
    val Tune by lazy { vec("tune", "M3 17v2h6v-2H3zM3 5v2h10V5H3zm10 16v-2h8v-2h-8v-2h-2v6h2zM7 9v2H3v2h4v2h2V9H7zm14 4v-2H11v2h10zm-6-4h2V7h4V5h-4V3h-2v6z") }
    val List by lazy { vec("list", "M3 13h2v-2H3v2zm0 4h2v-2H3v2zm0-8h2V7H3v2zm4 4h14v-2H7v2zm0 4h14v-2H7v2zM7 7v2h14V7H7z") }
    val Cloud by lazy { vec("cloud", "M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96z") }
    val Chart by lazy { vec("chart", "M3.5 18.49l6-6.01 4 4L22 6.92l-1.41-1.41-7.09 7.97-4-4L2 16.99z") }
    // robot vacuum seen from above: a ring with a bumper dot
    val Vacuum by lazy { vec("vacuum", "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zM10 8a2 2 0 1 0 4 0 2 2 0 1 0-4 0z") }
    val Grass by lazy { vec("grass", "M2 20h20v-2H2zm2-3l2.5-8L9 17zm6 0l2-11 2 11zm5 0l2.5-8L20 17z") }
    val Up by lazy { vec("up", "M7.41 15.41L12 10.83l4.59 4.58L18 14l-6-6-6 6z") }
    val Script by lazy { vec("script","M10 16.5l6-4.5-6-4.5v9zM12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8z") }
}

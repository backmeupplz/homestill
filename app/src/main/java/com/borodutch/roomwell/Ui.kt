@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)

package com.borodutch.roomwell

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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

@Composable
fun RoomwellTheme(content: @Composable () -> Unit) {
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
        Text("Roomwell", style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(top = 8.dp, bottom = 28.dp))
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
    sheet?.let { t -> ModalBottomSheet({ sheet = null }) { Detail(t) } }
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
    val on = !off && (s == "on" || s == "open" || s == "opening" || s == "unlocked" || s == "unlocking")
    val accent = if (d == "light") lightColor(e.a) else MaterialTheme.colorScheme.primary
    val flash = remember { Animatable(0f) }
    val scope = rememberCoroutineScope()
    val base = MaterialTheme.colorScheme.surfaceContainerHigh
    Column(
        Modifier.clip(RoundedCornerShape(20.dp))
            .background(if (on) accent.copy(alpha = 0.22f).compositeOver(base) else base)
            .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.35f * flash.value))
            .alpha(if (off) 0.45f else 1f)
            .combinedClickable(enabled = live && !off, onLongClick = if (d == "light" || d == "fan" || d == "cover") onSheet else null) {
                when (d) {
                    "lock" -> lockTap(s)?.let { (svc, ask) -> if (ask) onConfirm() else Ha.call("lock", svc, t.id, flip = optimistic(d, s)) }
                    "button", "input_button" -> Ha.call(d, "press", t.id)
                    "scene", "script" -> Ha.call(d, "turn_on", t.id)
                    else -> Ha.call(d, "toggle", t.id, flip = optimistic(d, s))
                }
                if (d in ACTION_DOMAINS) scope.launch { flash.snapTo(1f); flash.animateTo(0f, tween(700)) }
            }
            .padding(14.dp),
    ) {
        Icon(icon(d, s), null, tint = if (on) accent else MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(10.dp))
        Text(t.name, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(stateText(d, s, e.a), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
    }
}

fun icon(d: String, s: String) = when (d) {
    "light" -> Ic.Bulb
    "fan" -> Ic.Fan
    "cover" -> Ic.Window
    "lock" -> if (s == "locked" || s == "locking") Ic.Lock else Ic.LockOpen
    "button", "input_button" -> Ic.Button
    "scene" -> Ic.Scene
    "script" -> Ic.Script
    else -> Ic.Power
}

/** Long-press sheet for lights, fans and covers. */
@Composable
fun Detail(t: Tile) {
    val e = Ha.ents[t.id] ?: return
    val d = domain(t.id)
    val s = Ha.pending[t.id]?.s ?: e.s
    val f = e.a.optInt("supported_features")
    Column(Modifier.fillMaxWidth().padding(start = 24.dp, end = 24.dp, bottom = 32.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(t.name, style = MaterialTheme.typography.titleLarge)
                Text(stateText(d, s, e.a), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (d != "cover") Switch(s == "on", { Ha.call(d, if (it) "turn_on" else "turn_off", t.id, flip = if (it) "on" else "off") })
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
                    // right = warmer
                    Ctl("Warmth", lo + hi - (e.a.num("color_temp_kelvin")?.toFloat() ?: hi), lo..hi) {
                        Ha.call("light", "turn_on", t.id, JSONObject().put("color_temp_kelvin", Math.round(lo + hi - it)))
                    }
                }
                if (modes.any { it in HS_MODES }) Ctl("Color", e.a.optJSONArray("hs_color")?.optDouble(0)?.takeUnless { it.isNaN() }?.toFloat() ?: 0f, 0f..360f) {
                    Ha.call("light", "turn_on", t.id, JSONObject().put("hs_color", JSONArray().put(Math.round(it)).put(100)))
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
        }
    }
}

/** A slider that sends on release and at most every 300 ms while dragging, then follows the server again. */
@Composable
fun Ctl(label: String, server: Float, range: ClosedFloatingPointRange<Float>, send: (Float) -> Unit) {
    var v by remember { mutableStateOf<Float?>(null) }
    var dragging by remember { mutableStateOf(false) }
    var last by remember { mutableLongStateOf(0L) }
    LaunchedEffect(server) { if (!dragging) v = null }
    Text(label, style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(top = 20.dp))
    Slider(v ?: server.coerceIn(range), {
        v = it; dragging = true
        val now = SystemClock.uptimeMillis()
        if (now - last >= 300) { last = now; send(it) }
    }, valueRange = range, onValueChangeFinished = { dragging = false; v?.let(send) })
}

@Composable
fun Settings(onBack: () -> Unit) {
    val ctx = LocalContext.current
    val version = remember { ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName }
    Scaffold(topBar = { TopAppBar(title = { Text("Settings") }, navigationIcon = { IconButton(onBack) { Icon(Ic.Back, "Back") } }) }) { pad ->
        Column(Modifier.padding(pad)) {
            for ((k, v) in listOf("Server" to Ha.base.orEmpty(), "Signed in as" to Ha.user, "Version" to version.orEmpty()))
                ListItem(headlineContent = { Text(v) }, overlineContent = { Text(k) })
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
    val Script by lazy { vec("script", "M10 16.5l6-4.5-6-4.5v9zM12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8z") }
}

package com.borodutch.homestill

import android.app.Activity
import android.content.pm.ActivityInfo
import android.graphics.BitmapFactory
import android.os.SystemClock
import android.util.Log
import android.view.LayoutInflater
import androidx.annotation.OptIn
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.rotate
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.ui.PlayerView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import okhttp3.Request
import org.json.JSONObject

@Composable
fun CamerasScreen(onOpen: (String) -> Unit) {
    // LazyColumn disposes cards that leave the screen, which stops their players
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        items(Ha.cams, key = { it.id }) { t ->
            Column {
                CameraView(t.id, Modifier.fillMaxWidth().aspectRatio(16f / 9).clip(RoundedCornerShape(16.dp)).clickable { onOpen(t.id) })
                Text(t.name, style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(start = 4.dp, top = 6.dp))
            }
        }
    }
}

@Composable
fun FullCamera(id: String, onClose: () -> Unit) {
    val activity = LocalContext.current as Activity
    val view = LocalView.current
    DisposableEffect(Unit) {
        val bars = WindowCompat.getInsetsController(activity.window, view)
        activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        bars.hide(WindowInsetsCompat.Type.systemBars())
        onDispose { activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED; bars.show(WindowInsetsCompat.Type.systemBars()) }
    }
    var scale by remember { mutableFloatStateOf(1f) }
    var pan by remember { mutableStateOf(Offset.Zero) }
    val zoom = rememberTransformableState { z, p, _ -> scale = (scale * z).coerceIn(1f, 5f); pan = if (scale == 1f) Offset.Zero else pan + p }
    Box(Modifier.fillMaxSize().background(Color.Black).transformable(zoom)) {
        CameraView(id, Modifier.fillMaxSize().graphicsLayer { scaleX = scale; scaleY = scale; translationX = pan.x; translationY = pan.y })
        IconButton(onClose, Modifier.align(Alignment.TopStart).safeDrawingPadding().padding(8.dp)) { Icon(Ic.Close, "Close", tint = Color.White) }
        Ha.ptz[id]?.let { PtzPad(it, Modifier.align(Alignment.BottomEnd).safeDrawingPadding().padding(16.dp)) }
    }
}

/** Four arrows; each tap nudges the onvif camera [target] for 1 s (tap only: the picture lags, so holding would overshoot). */
@Composable
fun PtzPad(target: String, modifier: Modifier) {
    fun nudge(k: String, v: String) = Ha.call("onvif", "ptz", target,
        JSONObject().put(k, v).put("move_mode", "ContinuousMove").put("speed", 0.5).put("continuous_duration", 1))
    Box(modifier.size(132.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.35f))) {
        for ((at, turn, move) in listOf(Triple(Alignment.TopCenter, 0f, "tilt" to "UP"), Triple(Alignment.CenterEnd, 90f, "pan" to "RIGHT"),
            Triple(Alignment.BottomCenter, 180f, "tilt" to "DOWN"), Triple(Alignment.CenterStart, 270f, "pan" to "LEFT")))
            IconButton({ nudge(move.first, move.second) }, Modifier.align(at).size(44.dp)) {
                Icon(Ic.Up, move.second.lowercase(), Modifier.rotate(turn), tint = Color.White)
            }
    }
}

/** Live view of one camera: HLS when it offers it (snapshot poster until the first frame), else a snapshot every second. */
@Composable
fun CameraView(id: String, modifier: Modifier) {
    val s = Ha.ents[id]?.s
    if (s == null || s == "unavailable") {
        Box(modifier.background(Color.Black).alpha(0.6f), contentAlignment = Alignment.Center) { Text("Unavailable", color = Color.White) }
        return
    }
    var poster by remember(id) { mutableStateOf<ImageBitmap?>(null) }
    var url by remember(id) { mutableStateOf<String?>(null) }
    var tries by remember(id) { mutableIntStateOf(0) }
    var failed by remember(id) { mutableStateOf(false) }
    var playing by remember(id) { mutableStateOf(false) }
    val fg = Ha.foreground // nothing plays in the background
    LaunchedEffect(id, fg, tries) {
        url = null; playing = false
        if (!fg) return@LaunchedEffect
        snapshotFlow { Ha.status }.first { it == Status.Live }
        val caps = Ha.request(JSONObject().put("type", "camera/capabilities").put("entity_id", id)) as? JSONObject
        val hls = caps?.strings("frontend_stream_types")?.contains("hls") == true
        // `camera/stream` can fail even when hls is listed (cameras that only make stills): fall back to snapshots
        url = if (hls) (Ha.request(JSONObject().put("type", "camera/stream").put("entity_id", id)) as? JSONObject)?.str("url")?.let { Ha.base + it } else null
        if (url == null) while (true) { snapshot(id)?.let { poster = it }; delay(1000) }
        else if (poster == null) poster = snapshot(id)
    }
    Box(modifier.background(Color.Black), contentAlignment = Alignment.Center) {
        if (!playing) poster?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit) }
        url?.takeIf { !failed }?.let { u ->
            key(u) { Live(u, Modifier.fillMaxSize(), { playing = true }) { if (tries == 0) tries++ else failed = true } }
        }
        when {
            failed -> Text("Stream unavailable", color = Color.White)
            !playing && poster == null -> CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp)
        }
    }
}

private suspend fun snapshot(id: String): ImageBitmap? {
    val pic = Ha.ents[id]?.a?.str("entity_picture") ?: return null // read fresh: its token rotates
    val b = Ha.base ?: return null
    return withContext(Dispatchers.IO) {
        runCatching {
            Ha.http.newCall(Request.Builder().url(b + pic).build()).execute().use { r ->
                if (r.isSuccessful) BitmapFactory.decodeStream(r.body.byteStream())?.asImageBitmap() else null
            }
        }.getOrNull()
    }
}

@OptIn(UnstableApi::class)
@Composable
fun Live(url: String, modifier: Modifier, onFrame: () -> Unit, onError: () -> Unit) {
    val ctx = LocalContext.current
    val player = remember(url) {
        ExoPlayer.Builder(ctx)
            .setLoadControl(DefaultLoadControl.Builder().setBufferDurationsMs(1500, 5000, 500, 1000).build())
            .build().apply {
                volume = 0f
                val item = MediaItem.Builder().setUri(url).setLiveConfiguration(MediaItem.LiveConfiguration.Builder().setTargetOffsetMs(2000).build()).build()
                setMediaSource(HlsMediaSource.Factory(DefaultHttpDataSource.Factory()).createMediaSource(item))
                playWhenReady = true
                prepare()
            }
    }
    val started = remember(url) { SystemClock.uptimeMillis() }
    val frame by rememberUpdatedState(onFrame)
    val error by rememberUpdatedState(onError)
    DisposableEffect(player) {
        player.addListener(object : Player.Listener {
            override fun onRenderedFirstFrame() { Log.i("Homestill", "first frame ${SystemClock.uptimeMillis() - started} ms after the stream URL"); frame() }
            override fun onPlayerError(e: PlaybackException) = error()
        })
        onDispose { player.release() }
    }
    AndroidView({ (LayoutInflater.from(it).inflate(R.layout.player, null) as PlayerView).also { v -> v.player = player } }, modifier, update = { it.player = player })
}

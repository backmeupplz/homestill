package com.borodutch.homestill

import android.content.Context
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.Network
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.Toast
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.FormBody
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume

const val CLIENT_ID = "https://git.borodutch.com/backmeupplz/homestill"
private const val TAG = "Homestill"

class Msg(message: String) : Exception(message)

enum class Status { Connecting, Unreachable, Live }

/** An optimistic state shown until the server's state moves away from [server] (or 5 s pass). */
class Pending(val s: String, val server: String)

/** Auth, the one WebSocket, and the live model. Everything mutable is touched on the main thread only. */
object Ha {
    private lateinit var app: Context
    private lateinit var prefs: SharedPreferences
    private lateinit var cacheFile: File
    private val main = Handler(Looper.getMainLooper())
    private val scope = MainScope()
    val http: OkHttpClient = OkHttpClient.Builder().connectTimeout(10, TimeUnit.SECONDS).build()

    var base by mutableStateOf<String?>(null); private set // non-null = signed in
    private var refresh: String? = null
    var access: String? = null
    var expiresAt = 0L
    var readOnly = false // debug `noservice` extra: never call a service (looking at a real home)
    var notice by mutableStateOf<String?>(null) // shown on the sign-in screen
    var mfa by mutableStateOf(false) // the login flow is waiting for a code
    var status by mutableStateOf(Status.Connecting); private set
    var foreground by mutableStateOf(false); private set
    var user by mutableStateOf("")

    val ents = mutableStateMapOf<String, Ent>()
    val pending = mutableStateMapOf<String, Pending>()
    var sections by mutableStateOf(listOf<Section>()); private set
    var cams by mutableStateOf(listOf<Tile>()); private set
    var ptz by mutableStateOf(mapOf<String, String>()); private set // camera → the onvif entity that pans/tilts it
    private var reg: Map<String, Reg>? = null
    private var devArea: Map<String, String?>? = null
    private var areas: List<Pair<String, String>>? = null

    private var ws: WebSocket? = null
    private var gen = 0 // bumped per connection; callbacks from older sockets are dropped
    private var nextId = 1
    private val waiters = HashMap<Int, (JSONObject) -> Unit>()
    private var subId = -1
    private var fresh = false // the next entities event is the full set
    private var synced = false // full sync written to the cache since connecting
    private var attempt = 0
    private var authRetried = false
    private var net: Network? = null

    fun init(c: Context) {
        if (::app.isInitialized) return
        app = c.applicationContext
        prefs = app.getSharedPreferences("ha", Context.MODE_PRIVATE)
        cacheFile = File(app.filesDir, "home.json")
        base = prefs.getString("base", null)
        refresh = prefs.getString("refresh", null)
        if (base != null) loadCache()
        app.getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(n: Network) = main.post {
                val changed = net != null && n != net
                net = n
                if (foreground && (changed || status == Status.Unreachable)) connectNow()
            }.let {}
        })
    }

    // ---- HTTP + auth ----

    private fun exec(r: Request): Pair<Int, String> = http.newCall(r).execute().use { it.code to it.body.string() }
    private fun post(url: String, body: RequestBody) = exec(Request.Builder().url(url).post(body).build())
    private fun postJson(url: String, o: JSONObject): JSONObject {
        val (code, text) = post(url, o.toString().toRequestBody("application/json".toMediaType()))
        return runCatching { JSONObject(text) }.getOrElse { mfa = false; throw Msg("Sign-in failed (HTTP $code).") } // only the login flow uses this
    }

    /** The first base URL that answers /auth/providers, checked for the username/password provider. */
    private fun findServer(input: String): String {
        if (input.isBlank()) throw Msg("Enter your Home Assistant address.")
        var lastErr: IOException? = null
        for (b in candidates(input)) {
            val text = try { exec(Request.Builder().url("$b/auth/providers").build()).second } catch (e: IOException) { lastErr = e; continue } catch (e: IllegalArgumentException) { throw Msg("That address doesn't look right.") }
            val list = runCatching { JSONObject(text).getJSONArray("providers") }.getOrElse { runCatching { JSONArray(text) }.getOrNull() }
                ?: throw Msg("That doesn't look like Home Assistant.")
            if ((0 until list.length()).none { list.getJSONObject(it).optString("type") == "homeassistant" })
                throw Msg("This server needs a sign-in method Homestill doesn't support yet.")
            return b
        }
        throw Msg("Can't reach that server${lastErr?.message?.let { " ($it)" } ?: ""}.")
    }

    private var flowBase = ""
    private var flowId = ""

    /** Runs the login flow (or its MFA step when [mfa]); on success stores the session and connects. Throws [Msg] to show. */
    suspend fun login(input: String, username: String, password: String, code: String) = withContext(Dispatchers.IO) {
        try {
            var r = if (mfa) postJson("$flowBase/auth/login_flow/$flowId", JSONObject().put("client_id", CLIENT_ID).put("code", code.trim()))
            else {
                flowBase = findServer(input)
                val f = postJson("$flowBase/auth/login_flow", JSONObject().put("client_id", CLIENT_ID).put("handler", JSONArray().put("homeassistant").put(JSONObject.NULL)).put("redirect_uri", CLIENT_ID))
                flowId = f.optString("flow_id")
                postJson("$flowBase/auth/login_flow/$flowId", JSONObject().put("client_id", CLIENT_ID).put("username", username.trim()).put("password", password))
            }
            while (true) {
                when (r.optString("type")) {
                    "create_entry" -> break
                    "abort" -> { mfa = false; throw Msg(r.optString("reason").ifEmpty { "Sign-in failed." }) }
                    "form" -> {
                        flowId = r.optString("flow_id", flowId)
                        val err = r.optJSONObject("errors")?.str("base")
                        when (r.optString("step_id")) {
                            "select_mfa_module" -> {
                                val opts = r.getJSONArray("data_schema").getJSONObject(0).get("options")
                                val first = (opts as? JSONArray)?.get(0)?.let { (it as? JSONArray)?.getString(0) ?: it.toString() } ?: (opts as JSONObject).keys().next()
                                r = postJson("$flowBase/auth/login_flow/$flowId", JSONObject().put("client_id", CLIENT_ID).put("multi_factor_auth_module", first))
                            }
                            "mfa" -> { val wasMfa = mfa; mfa = true; if (wasMfa || err != null) throw Msg(if (err == "invalid_code") "Wrong code." else err ?: "Enter the code."); return@withContext }
                            else -> throw Msg(if (err == "invalid_auth") "Wrong username or password." else err ?: "Sign-in failed.")
                        }
                    }
                    else -> { mfa = false; throw Msg(r.optString("message").ifEmpty { "Sign-in failed." }) } // e.g. the flow is gone after an HA restart
                }
            }
            val (code2, text) = post("$flowBase/auth/token", FormBody.Builder().add("grant_type", "authorization_code").add("code", r.getString("result")).add("client_id", CLIENT_ID).build())
            if (code2 != 200) throw Msg("Sign-in failed (HTTP $code2).")
            val t = JSONObject(text)
            withContext(Dispatchers.Main) {
                mfa = false; notice = null
                access = t.getString("access_token"); expiresAt = System.currentTimeMillis() + t.optLong("expires_in", 1800) * 1000
                refresh = t.getString("refresh_token"); base = flowBase
                prefs.edit().putString("base", base).putString("refresh", refresh).apply()
                connectNow()
            }
        } catch (e: IOException) { throw Msg("Can't reach that server (${e.message}).") }
        catch (e: JSONException) { throw Msg("Unexpected answer from Home Assistant.") }
    }

    /** A usable access token (refreshed when missing or about to expire); null = the session ended (already signed out). Call off main. */
    @Synchronized private fun token(): String? {
        if (!needsRefresh(access, expiresAt, System.currentTimeMillis())) return access
        val b = base ?: return null
        val r = refresh ?: return null
        val (code, text) = post("$b/auth/token", FormBody.Builder().add("grant_type", "refresh_token").add("refresh_token", r).add("client_id", CLIENT_ID).build())
        if (code == 400) { // invalid_grant; anything else is a transient failure, not a sign-out
            main.post { if (base == b) signOut("Your session ended. Sign in again.") }; return null }
        if (code != 200) throw IOException("HTTP $code")
        val t = runCatching { JSONObject(text).also { it.getString("access_token") } }.getOrElse { throw IOException("unexpected token reply") } // e.g. a proxy's login page
        access = t.getString("access_token"); expiresAt = System.currentTimeMillis() + t.optLong("expires_in", 1800) * 1000
        Log.i(TAG, "access token refreshed")
        return access
    }

    fun signOut(why: String? = null) {
        val b = base; val r = refresh
        if (why == null && b != null && r != null) scope.launch(Dispatchers.IO) { runCatching { post("$b/auth/token", FormBody.Builder().add("token", r).add("action", "revoke").build()) } }
        close(); prefs.edit().clear().apply(); cacheFile.delete()
        base = null; refresh = null; access = null; expiresAt = 0; user = ""; notice = why
        ents.clear(); pending.clear(); sections = emptyList(); cams = emptyList(); ptz = emptyMap(); reg = null; devArea = null; areas = null
    }

    // ---- socket ----

    fun start() { foreground = true; connectNow() }
    fun stop() { foreground = false; if (base != null) { close(); saveCache() } }

    /** Reconnect right away with a fresh backoff (foreground, network change, banner tap). */
    fun connectNow() { attempt = 0; status = Status.Connecting; connect() }

    private fun close() { gen++; ws?.close(1000, null); ws = null; waiters.clear(); status = Status.Connecting }

    private fun connect() {
        if (base == null || !foreground) return
        ws?.cancel(); ws = null; waiters.clear()
        val g = ++gen
        val url = base!!.replaceFirst("http", "ws") + "/api/websocket"
        scope.launch {
            val t = try { withContext(Dispatchers.IO) { token() } } catch (e: IOException) { Log.i(TAG, "refresh failed: $e"); failed(g); return@launch }
            if (t == null || g != gen) return@launch
            ws = http.newWebSocket(Request.Builder().url(url).build(), object : WebSocketListener() {
                override fun onMessage(webSocket: WebSocket, text: String) {
                    val m = runCatching { JSONObject(text) }.getOrNull() ?: return // parse off the main thread
                    main.post { if (g == gen) handle(g, m) }
                }
                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { main.post { failed(g) } }
                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { main.post { failed(g) } } // server closed: don't wait for its timeout
                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { main.post { failed(g) } }
            })
        }
    }

    private fun failed(g: Int) {
        if (g != gen || base == null) return
        ws?.cancel(); ws = null; waiters.clear()
        val g2 = ++gen
        status = Status.Unreachable
        val delay = minOf(30, 1 shl minOf(attempt, 5)) * 1000L
        attempt++
        main.postDelayed({ if (g2 == gen) connect() }, delay)
    }

    private fun send(msg: JSONObject, reply: ((JSONObject) -> Unit)? = null): Int {
        val id = nextId++
        msg.put("id", id)
        reply?.let { waiters[id] = it }
        ws?.send(msg.toString())
        return id
    }

    private fun handle(g: Int, m: JSONObject) {
        when (m.optString("type")) {
            "auth_required" -> ws?.send(JSONObject().put("type", "auth").put("access_token", access).toString()) // no id: HA rejects extra keys here
            "auth_ok" -> {
                Log.i(TAG, "auth_ok")
                authRetried = false; attempt = 0; status = Status.Live; synced = false
                fresh = true
                subId = send(JSONObject().put("type", "subscribe_entities"))
                send(JSONObject().put("type", "config/entity_registry/list_for_display")) { r -> ok(r)?.let { reg = parseEntityReg(it as JSONObject); rebuild() } }
                send(JSONObject().put("type", "config/device_registry/list")) { r -> ok(r)?.let { devArea = parseDevices(it as JSONArray); rebuild() } }
                send(JSONObject().put("type", "config/area_registry/list")) { r -> ok(r)?.let { areas = parseAreas(it as JSONArray); rebuild() } }
                send(JSONObject().put("type", "auth/current_user")) { r -> (ok(r) as? JSONObject)?.str("name")?.let { user = it } }
                ping(g)
            }
            "auth_invalid" -> {
                Log.i(TAG, "auth_invalid (retried=$authRetried)")
                if (authRetried) signOut("Your session ended. Sign in again.")
                else { authRetried = true; access = null; connect() } // HA closes this socket; the new generation ignores that
            }
            "event" -> if (m.optInt("id") == subId) m.optJSONObject("event")?.let { ev ->
                if (fresh) { ents.clear(); fresh = false }
                val touched = applyEvent(ents, ev)
                for (id in touched) pending[id]?.let { if (ents[id]?.s != it.server) pending.remove(id) }
                if (touched.isNotEmpty()) rebuild()
            }
            else -> waiters.remove(m.optInt("id"))?.invoke(m)
        }
    }

    private fun ok(r: JSONObject): Any? = if (r.optBoolean("success")) r.opt("result") else null.also { Log.w(TAG, "command failed: $r") }

    private fun rebuild() {
        val r = reg ?: return; val d = devArea ?: return; val a = areas ?: return
        if (fresh) return
        sections = buildHome(ents, r, d, a)
        cams = buildCameras(ents, r)
        ptz = ptzTargets(cams, r, d, a)
        if (!synced) { synced = true; saveCache() }
    }

    private fun ping(g: Int) {
        main.postDelayed({
            if (g != gen) return@postDelayed
            var got = false
            send(JSONObject().put("type", "ping")) { got = true }
            main.postDelayed({ if (!got) failed(g) }, 10_000)
            ping(g)
        }, 20_000)
    }

    /** One command → its result (null on failure or a dropped socket). */
    suspend fun request(msg: JSONObject): Any? = suspendCancellableCoroutine { c ->
        if (status != Status.Live) { c.resume(null); return@suspendCancellableCoroutine }
        send(msg) { r -> if (c.isActive) c.resume(ok(r)) }
        main.postDelayed({ if (c.isActive) c.resume(null) }, 15_000)
    }

    /** Sends a service call at once; [flip] shows that state until the server confirms (or 5 s / a failure put it back). */
    fun call(domain: String, service: String, id: String, data: JSONObject = JSONObject(), flip: String? = null) {
        if (status != Status.Live) return
        if (readOnly) { Toast.makeText(app, "Read-only: $domain.$service not sent", Toast.LENGTH_SHORT).show(); return }
        val p = ents[id]?.s?.let { s -> flip?.let { Pending(it, s) } }
        if (p != null) { pending[id] = p; main.postDelayed({ if (pending[id] === p) pending.remove(id) }, 5_000) }
        send(JSONObject().put("type", "call_service").put("domain", domain).put("service", service).put("service_data", data).put("target", JSONObject().put("entity_id", id))) { r ->
            if (!r.optBoolean("success")) {
                if (p != null && pending[id] === p) pending.remove(id)
                Toast.makeText(app, r.optJSONObject("error")?.str("message") ?: "That didn't work.", Toast.LENGTH_SHORT).show()
            }
        }
    }

    // ---- snapshot cache: draw the last known home at once on launch ----

    private fun saveCache() {
        val shown = sections.flatMap { it.tiles } + cams
        if (shown.isEmpty()) return
        val o = JSONObject()
        fun tile(t: Tile) = JSONArray().put(t.id).put(t.name).apply { t.dp?.let { put(it) } }
        o.put("sections", JSONArray(sections.map { s -> JSONObject().put("t", s.title).put("tiles", JSONArray(s.tiles.map(::tile))) }))
        o.put("cams", JSONArray(cams.map(::tile)))
        val e = JSONObject()
        for (t in shown) ents[t.id]?.let { x -> e.put(t.id, JSONObject().put("s", x.s).put("a", x.a)) }
        o.put("ents", e)
        val text = o.toString()
        scope.launch(Dispatchers.IO) { runCatching { cacheFile.writeText(text) } }
    }

    private fun loadCache() = runCatching {
        val o = JSONObject(cacheFile.readText())
        fun tiles(a: JSONArray) = List(a.length()) { a.getJSONArray(it).let { t -> Tile(t.getString(0), t.getString(1), if (t.length() > 2) t.getInt(2) else null) } }
        val e = o.getJSONObject("ents")
        for (id in e.keys()) e.getJSONObject(id).let { ents[id] = Ent(it.getString("s"), it.getJSONObject("a")) }
        val s = o.getJSONArray("sections")
        sections = List(s.length()) { s.getJSONObject(it).let { x -> Section(x.getString("t"), tiles(x.getJSONArray("tiles"))) } }
        cams = tiles(o.getJSONArray("cams"))
    }
}

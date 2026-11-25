# Roomwell spec

Roomwell is a small, fast Home Assistant client that does two things: control devices and watch cameras. Native on both
phones: Android at the repo root (`app/`, Kotlin, Jetpack Compose + Material 3) and iPhone in `ios/` (SwiftUI). Both apps
follow this document; when a platform has to differ, it says so here. Sister apps whose layout and habits we copy:
Spinwell (`~/code/spinwell-main`, the closest: Compose + SwiftUI, SPEC-driven) and ABS+ (`~/code/absplus`).

"Roomwell" is a working name (not confirmed yet), so keep it in as few places as possible: app name, package/bundle id,
project names. No dashboards, history, sensors, automations, notifications, widgets, energy, map or settings editor.

## Platforms

- Android: package `com.borodutch.roomwell`, minSdk 29, target/compile 36, AGP/Gradle/Kotlin versions as Spinwell.
  Dependencies: Compose BOM + ui + foundation + material3 + activity-compose (as Spinwell), `com.squareup.okhttp3:okhttp`
  (WebSocket; Android has no platform client), `androidx.media3:media3-exoplayer` + `media3-exoplayer-hls` + `media3-ui`
  (camera video). Nothing else: `org.json` for JSON, no Retrofit/Coil/Room/serialization/ViewModel/DI. R8 on for release.
  Single activity, state in plain Kotlin objects observed by Compose (`mutableStateOf`/`mutableStateMapOf`).
  `android:usesCleartextTraffic="true"` (Home Assistant on the LAN is often plain http).
- iOS: bundle `com.borodutch.roomwell`, team `ACWP4F58HZ`, iOS 26.1+, iPhone only, Swift 5 mode, no packages.
  `URLSessionWebSocketTask`, AVKit for video, Keychain for the refresh token. Project file like Spinwell
  (`PBXFileSystemSynchronizedRootGroup`, so new files need no pbxproj edits). Info.plist: `NSAllowsArbitraryLoads = true`,
  `NSAllowsLocalNetworking = true`, `NSLocalNetworkUsageDescription` ("Roomwell connects to Home Assistant on your network.").
- English only for now. Follows the system light/dark theme (Android: Material You dynamic color on 12+).

## Speed is the feature

- Cold start draws the last known home from disk at once (target < 300 ms to tiles), then goes live.
- A tap sends the service call immediately and flips the tile optimistically; the live state confirms it.
- One WebSocket for everything. No polling. Nothing runs in the background: the socket closes when the app leaves the
  foreground and reconnects when it returns.

## Sign-in (username + password, native form, no browser)

- Fields: server URL, username, password. URL normalization: trim, drop trailing `/`; no scheme → try `https://` then
  `http://` (first that answers `GET /auth/providers` wins).
- `GET <base>/auth/providers`: must list a provider of type `homeassistant`, else show "This server needs a sign-in
  method Roomwell doesn't support yet."
- `CLIENT_ID = "https://git.borodutch.com/backmeupplz/roomwell"` on both platforms; `redirect_uri` = the same string
  (same origin as the client id, so Home Assistant never fetches it). It names the app in the user's HA token list.
- Flow (JSON bodies):
  1. `POST /auth/login_flow` `{"client_id":CLIENT_ID,"handler":["homeassistant",null],"redirect_uri":CLIENT_ID}`
     → `{"type":"form","flow_id":…,"step_id":"init"}`.
  2. `POST /auth/login_flow/<flow_id>` `{"client_id":CLIENT_ID,"username":…,"password":…}` →
     - `{"type":"create_entry","result":"<code>"}` → step 3;
     - `{"type":"form","step_id":"init","errors":{"base":"invalid_auth"}}` → "Wrong username or password." (any other
       `errors.base` → show it raw);
     - `{"type":"form","step_id":"select_mfa_module"}` → post `{"client_id":…,"multi_factor_auth_module":<first option>}`
       (options are in `data_schema[0].options`) and continue;
     - `{"type":"form","step_id":"mfa"}` → show a "Code" field (password and username hidden), post
       `{"client_id":…,"code":…}`; `errors.base == "invalid_code"` → "Wrong code.";
     - `{"type":"abort"}` → show `reason`, restart from step 1.
  3. `POST /auth/token` (form-urlencoded) `grant_type=authorization_code&code=…&client_id=…` →
     `{"access_token","expires_in":1800,"refresh_token","token_type":"Bearer"}`.
- Store server base URL + refresh token only (iOS Keychain; Android app-private SharedPreferences). The access token and
  its expiry live in memory.
- Refresh: `POST /auth/token` form `grant_type=refresh_token&refresh_token=…&client_id=…`. Refresh whenever the access
  token is missing or expires within 60 s, before every (re)connect and before any HTTP call. HTTP 400 (`invalid_grant`)
  → signed out: back to sign-in with "Your session ended. Sign in again." Network errors are not sign-outs.
- Sign out (Settings): `POST /auth/token` form `token=<refresh_token>&action=revoke` (ignore failures), wipe storage
  and caches, back to sign-in.

## WebSocket API

- `ws(s)://<base>/api/websocket`. Server sends `auth_required` → send `{"type":"auth","access_token":…}` → `auth_ok`.
  `auth_invalid` → refresh the token and retry once; a second `auth_invalid` → signed out (as above).
- Every command has an increasing integer `id`; replies are `{"id","type":"result","success",…}`. After `auth_ok`, send
  these at once (pipelined):
  - `{"type":"subscribe_entities"}` → `result` then events with `event` of:
    - `{"a":{entity_id:{"s":state,"a":attrs,"c":ctx,"lc":lastChanged,"lu":lastUpdated?}}}` — added / full state
      (the first event holds every entity);
    - `{"c":{entity_id:{"+":{"s"?, "a"?:{changed attrs}, "lc"?, "lu"?, "c"?},"-":{"a":[removed attr keys]}}}}` —
      diffs: merge `+.a` into attributes, delete `-.a` keys, replace `s` if present;
    - `{"r":[entity_id…]}` — removed.
    One event may carry several of `a`/`c`/`r`.
  - `{"type":"config/entity_registry/list_for_display"}` → `{"entities":[{"ei":entity_id,"di"?:device_id,
    "ai"?:area_id,"ec"?:0|1,"hb"?:true,"en"?:name,…}],"entity_categories":{"0":"config","1":"diagnostic"}}`.
  - `{"type":"config/device_registry/list"}` → `[{"id","area_id","name_by_user","name",…}]`.
  - `{"type":"config/area_registry/list"}` → `[{"area_id","name","icon",…}]` (list order = display order).
  - `{"type":"auth/current_user"}` → `{"name",…}` (Settings).
- Controls: `{"type":"call_service","domain","service","service_data":{…},"target":{"entity_id":…}}`. A failed
  result reverts the optimistic tile and shows the error `message` in a short snackbar/toast.
- Cameras: `{"type":"camera/capabilities","entity_id"}` → `{"frontend_stream_types":["hls","web_rtc"]}`;
  `{"type":"camera/stream","entity_id"}` → `{"url":"/api/hls/<token>/master_playlist.m3u8"}` (the path carries its own
  token: play `<base>+url` with no auth header).
- Heartbeat: `{"type":"ping"}` every 20 s while connected; no `pong` within 10 s → reconnect.
- Reconnect with backoff 1, 2, 4 … 30 s; immediately on returning to the foreground and on a network change (Android
  default-network callback, iOS `NWPathMonitor`). Each reconnect re-subscribes and refetches the three registries.
- Debug builds only: a launch flag (`-badtoken 1` on iOS, intent extra `badtoken` on Android) that replaces the
  in-memory access token with `"x"` (future expiry) before the first connect, to exercise auth_invalid → refresh → connected.

## What is shown

- Entities from domains `light switch input_boolean fan cover lock button input_button scene script` on Home,
  `camera` on Cameras. Everything else is ignored. Skip registry entries with `hb` (hidden) or `ec` set (config/diagnostic).
- Area of an entity: its own `ai`, else its device's `area_id`, else none. Home lists areas in area-registry order
  (only those with entities), then "Other" for entities without an area. Scenes and scripts go to a "Scenes" section
  at the top if they have no area.
- Name: `attributes.friendly_name` (else the entity id). If it starts with the area name followed by a space (case
  insensitive) and something is left, drop that prefix ("Living Room Lights" in Living Room → "Lights"). Within a section
  sort by displayed name. Never derive anything from the entity id beyond its domain: ids and names can disagree.
- Snapshot cache: after each full sync and on going to the background, write the shown model (areas, entities with
  state + the attributes we use) to one JSON file in app storage; at launch draw it at once, dimmed until connected.

## Home screen

- Top bar: title "Home", a gear → Settings. A slim banner under it when not connected: "Connecting…" or
  "Can't reach Home Assistant" (tap retries now). While not connected tiles are dimmed and taps do nothing.
- Sections per area, each a 2-column grid of tiles (rounded cards: icon, name, one-line state). "On"-like tiles are
  tinted: lights by their `rgb_color` when on (fallback amber), other toggles by the accent color.
- `unavailable`/`unknown` state (except buttons/scenes/scripts, whose state is a timestamp or `unknown` by design): dimmed,
  state text "Unavailable", not tappable.
- Tap behavior:
  - `light switch input_boolean fan`: `<domain>.toggle`. Light state text = "On · 60%" (from `brightness`/255) or "Off".
  - `cover`: `cover.toggle`; state text from `s` (Open/Closed/Opening/Closing) + `current_position`% if present.
  - `lock`: state `locked` → confirm dialog "Unlock <name>?" (destructive style) → `lock.unlock`; `unlocked`/`open` →
    `lock.lock` without a confirm; `jammed` → shows "Jammed", tap = `lock.lock` with no confirm; `locking`/`unlocking`/`opening` → no-op.
  - `button`/`input_button`: `<domain>.press`; `scene`: `scene.turn_on`; `script`: `script.turn_on`. Flash the tile.
- Long-press (Android) / context-press or a small chevron (iOS: `.contextMenu` is fine, or a sheet on long press) opens
  a detail sheet for lights, fans and covers:
  - light: on/off switch; brightness slider (if `supported_color_modes` has anything other than `onoff`) →
    `light.turn_on {"brightness_pct"}`; warmth slider if modes include `color_temp` (range `min_color_temp_kelvin`
    …`max_color_temp_kelvin`) → `{"color_temp_kelvin"}`; hue slider if modes include any of `hs rgb rgbw rgbww xy` →
    `{"hs_color":[h,100]}`. Sliders send on release and at most every 300 ms while dragging.
  - fan: on/off + speed slider if `supported_features & 1` → `fan.set_percentage {"percentage"}`.
  - cover: Open / Stop / Close buttons (`cover.open_cover`/`stop_cover`/`close_cover`) + position slider if
    `supported_features & 4` → `cover.set_cover_position {"position"}`.
- Optimistic update: flip `s` locally at once; if the server's state hasn't confirmed within 5 s (or the call fails),
  put back the last server state.

## Cameras screen

- Bottom tabs "Home" and "Cameras" (the Cameras tab only when there is at least one camera).
- A vertical list of 16:9 cards, one per camera, name under each. Cards on screen play live, muted, at once:
  - if `camera/capabilities` lists `hls`: `camera/stream` → play the HLS URL (iOS `AVPlayer`; Android ExoPlayer
    `HlsMediaSource`, low-latency live config, target offset ~2 s). Home Assistant serves low-latency HLS (H.264,
    1 s parts), so first frame should be ~1–2 s. While waiting, show the snapshot poster (below) or a dark placeholder
    with a spinner. On a playback error request a new stream URL once, then show "Stream unavailable".
  - otherwise: refresh the snapshot every 1 s.
  - Snapshot: `<base>` + `attributes.entity_picture` (it carries a `token=` query; no auth header). It may answer 500
    (some cameras can't make stills): then there's no poster.
- Cards scrolled off screen stop their player. `unavailable` camera: dimmed card "Unavailable", no player.
- Tap a card → full-screen live view of that camera (black background, aspect-fit, pinch to zoom, rotates to landscape,
  close button / back). Same player logic.

## Settings

- Server URL, signed-in user name (`auth/current_user`), app version, "Sign out". Nothing else.

## Tests and checks

- Unit tests (pure logic, no network): applying `subscribe_entities` events (a/c/r merging), building the Home model
  (domain filter, hidden/category skip, area resolution entity→device→Other, prefix stripping, sort), lock tap decision,
  token-needs-refresh decision. Android JUnit (`testDebugUnitTest`), iOS XCTest target `RoomwellTests`.
- Control testing happens only against the throwaway demo server (`tools/demo-ha.sh`: Docker Home Assistant with the
  `demo` integration on :8124, user `demo` / `demo-pass`; emulator uses `http://10.0.2.2:8124`). The real home server
  (`https://home.icefish-betta.ts.net`) holds real door locks and lights people are using: sign in, look, and watch the
  cameras, but never call a service on it from tests.

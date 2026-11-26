# Homestill spec

Homestill is a small, fast Home Assistant client that does two things: control devices (and glance at the readings in
each room) and watch cameras. Native on both
phones: Android at the repo root (`app/`, Kotlin, Jetpack Compose + Material 3) and iPhone in `ios/` (SwiftUI). Both apps
follow this document; when a platform has to differ, it says so here. Sister apps whose layout and habits we copy:
Spinwell (`~/code/spinwell-main`, the closest: Compose + SwiftUI, SPEC-driven) and ABS+ (`~/code/absplus`).

No dashboards, history, graphs, automations, notifications, widgets, energy, map or settings editor. Sensors appear
only as one-line readings inside rooms.

## Platforms

- Android: package `com.borodutch.homestill`, minSdk 29, target/compile 36, AGP/Gradle/Kotlin versions as Spinwell.
  Dependencies: Compose BOM + ui + foundation + material3 + activity-compose (as Spinwell), `com.squareup.okhttp3:okhttp`
  (WebSocket; Android has no platform client; 5.3.x, since 5.5 needs compileSdk 37), `androidx.media3:media3-exoplayer` + `media3-exoplayer-hls` + `media3-ui`
  (camera video). Nothing else: `org.json` for JSON, no Retrofit/Coil/Room/serialization/ViewModel/DI. R8 on for release.
  Single activity, state in plain Kotlin objects observed by Compose (`mutableStateOf`/`mutableStateMapOf`).
  `android:usesCleartextTraffic="true"` (Home Assistant on the LAN is often plain http).
- iOS: bundle `com.borodutch.homestill`, team `ACWP4F58HZ`, iOS 26.1+, iPhone only, Swift 5 mode, no packages.
  `URLSessionWebSocketTask`, AVKit for video, Keychain for the refresh token. Project file like Spinwell
  (`PBXFileSystemSynchronizedRootGroup`, so new files need no pbxproj edits). Info.plist: `NSAllowsArbitraryLoads = true`
  and `NSLocalNetworkUsageDescription` ("Homestill connects to Home Assistant on your network."). No
  `NSAllowsLocalNetworking`: when present, iOS ignores `NSAllowsArbitraryLoads` and blocks plain http to dotted hostnames
  (checked: `http://<mac>.<tailnet>.ts.net:8124` failed with error -1022 until the key was removed).
- English only for now. Follows the system light/dark theme (Android: Material You dynamic color on 12+).
- Releases (as Spinwell): a published Forgejo release `vX.Y.Z` runs `.forgejo/workflows/release.yml`: AAB to Google Play,
  iPhone build to App Review (`ios/release.sh`), signed APK as `homestill-X.Y.Z.apk` + `homestill.apk` on the Forgejo
  and GitHub releases. Version = `versionName`/`versionCode` in `app/build.gradle.kts` (iOS build number = versionCode);
  notes in `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt`, store texts in `appstore/` and `fastlane/`.

## Speed is the feature

- Cold start draws the last known home from disk at once (target < 300 ms to tiles), then goes live.
- A tap sends the service call immediately and flips the tile optimistically; the live state confirms it.
- One WebSocket for everything. No polling. Nothing runs in the background: the socket closes when the app leaves the
  foreground and reconnects when it returns.

## Sign-in (username + password, native form, no browser)

- Fields: server URL, username, password. URL normalization: trim, drop trailing `/`; no scheme → try `https://` then
  `http://` (first that answers `GET /auth/providers` wins).
- `GET <base>/auth/providers`: must list a provider of type `homeassistant`, else show "This server needs a sign-in
  method Homestill doesn't support yet."
- `CLIENT_ID = "https://git.borodutch.com/backmeupplz/homestill"` on both platforms; `redirect_uri` = the same string
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
     - `{"type":"abort"}` → show `reason`, restart from step 1;
     - anything else (e.g. `{"message":"Invalid flow specified"}` after HA restarted mid-flow) → show `message`, back
       to the username and password fields (restart from step 1).
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
  Camera cards follow the reconnect rule under "Cameras screen".
- Debug builds only: a launch flag (`-badtoken 1` on iOS, intent extra `badtoken` on Android) that replaces the
  in-memory access token with `"x"` (future expiry) before the first connect, to exercise auth_invalid → refresh → connected.
  Android debug builds also take an intent extra `noservice` that drops every `call_service` (for looking at a real home).

## What is shown

- Home shows two kinds of entities (the domains in the table under "Home screen"); `camera` goes to Cameras. Every
  other domain (person, zone, sun, update, event, calendar, text, date/time, tts, notify, …) is ignored. Skip registry
  entries with `hb` (hidden) or `ec` set (config/diagnostic).
  - Controls: `light switch input_boolean fan cover lock button input_button scene script siren remote valve
    climate water_heater humidifier media_player vacuum lawn_mower alarm_control_panel`.
  - Settings and readings: `number input_number select input_select sensor binary_sensor weather`. These are shown
    only when they have an area and their state is not `unavailable`/`unknown` (a home is full of area-less backup
    sensors and device knobs; an unavailable reading is noise). Sensors with `device_class` `timestamp` are skipped.
- Area of an entity: its own `ai`, else its device's `area_id`, else none. Home lists areas in area-registry order
  (only those with entities), then "Other" for controls without an area. Scenes and scripts go to a "Scenes" section
  at the top if they have no area.
- Keep every attribute of a shown entity (no whitelist), in memory and in the snapshot cache: the controls below read
  many of them. iOS keeps them as a `[String: Any]`-like JSON value (persisted as JSON), Android as the `JSONObject`.
- Name: `attributes.friendly_name` (else the entity id). If it starts with the area name followed by a space (case
  insensitive) and something is left, drop that prefix ("Living Room Lights" in Living Room → "Lights"). Within a section
  sort by displayed name. Never derive anything from the entity id beyond its domain: ids and names can disagree.
- Snapshot cache: after each full sync and on going to the background, write the shown model (areas, entities with
  state + the attributes we use) to one JSON file in app storage; at launch draw it at once, dimmed until connected.

## Home screen

- Top bar: title "Home", a gear → Settings. A slim banner under it when not connected: "Connecting…" or
  "Can't reach Home Assistant" (tap retries now). While not connected tiles are dimmed and taps do nothing.
- Sections per area, each a 2-column grid of tiles (rounded cards: icon, name, one-line state). Within a section,
  controls first, then settings and readings, each sorted by name. "On"-like tiles are tinted: lights by their
  `rgb_color` when on (fallback amber, also for near-white colors, which would vanish on a light background), other
  controls by the accent color when active (column "Active" below). Readings are never tinted and not tappable.
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
    `light.turn_on {"brightness_pct"}`; warmth bar if modes include `color_temp` (range `min_color_temp_kelvin`
    …`max_color_temp_kelvin`, warm on the left, drawn as an amber → white → cool-blue gradient) →
    `{"color_temp_kelvin"}`; color wheel if modes include any of `hs rgb rgbw rgbww xy` (angle = hue, clockwise from
    red at 3 o'clock; distance from the center = saturation; white center; a thumb in the picked color at `hs_color`;
    tap or drag) → `{"hs_color":[h,s]}`. Sliders, bars and the wheel send on release and at most every 300 ms while dragging.
  - fan: on/off + speed slider if `supported_features & 1` → `fan.set_percentage {"percentage"}`.
  - cover: Open / Stop / Close buttons (`cover.open_cover`/`stop_cover`/`close_cover`) + position slider if
    `supported_features & 4` → `cover.set_cover_position {"position"}`.
### More devices

The sheet is built from a few control kinds, the same on both platforms: switch, slider (sends like the light
sliders), stepper (− value +, sends 600 ms after the last press), picker (menu of strings; shows the current one),
action buttons (a row of tonal buttons), code field. `f` = `supported_features`; a row whose feature bit is missing,
or whose list attribute is empty, is left out. Every call targets the tile's entity. Long-press (iOS: the same
gesture as lights) opens the sheet for every domain that has one, also where a tap acts. The sheet's title is the
name, its subtitle the state text, as for lights. Service names and feature bits
were read from Home Assistant 2026.11.

| Domain | State text | Active | Tap | Sheet |
|---|---|---|---|---|
| `siren` | On / Off | on | opens the sheet (no accidental alarms) | switch → `turn_on` / `turn_off` |
| `remote` | On / Off | on | `remote.toggle` (optimistic) | none |
| `valve` | Open / Closed / Opening / Closing + `current_position`% | open, opening | `valve.toggle` (optimistic open/closed) | Open / Stop / Close (f&1 `open_valve`, f&8 `stop_valve`, f&2 `close_valve`); position slider if f&4 → `set_valve_position {"position"}` |
| `climate` | hvac mode label + ` · ` + `current_temperature` + unit ("Heat · 21.5 °C"; "Off · 19 °C") | state ≠ off | opens the sheet | header line: `hvac_action` label if present; target stepper if f&1 and mode isn't `heat_cool` → `set_temperature {"temperature"}`; low and high steppers if f&2 and mode is `heat_cool` → `set_temperature {"target_temp_low","target_temp_high"}` (both sent); mode picker (`hvac_modes`) → `set_hvac_mode {"hvac_mode"}`; preset picker if f&16 (`preset_modes`) → `set_preset_mode {"preset_mode"}`; fan picker if f&8 (`fan_modes`) → `set_fan_mode {"fan_mode"}`. Stepper bounds `min_temp`…`max_temp`, step `target_temp_step`, else 0.5 for °C and 1 for °F |
| `water_heater` | `operation_mode` label + ` · ` + `temperature` + unit | state ≠ off | opens the sheet | switch if f&8 → `turn_on` / `turn_off`; target stepper if f&1 → `set_temperature {"temperature"}` (bounds/step as climate); operation picker if f&2 (`operation_list`) → `set_operation_mode {"operation_mode"}`; away switch if f&4 → `set_away_mode {"away_mode": bool}` |
| `humidifier` | On · `humidity`% / Off | on | `humidifier.toggle` (optimistic) | switch; target slider `min_humidity`…`max_humidity` (step `target_humidity_step`, else 1) → `set_humidity {"humidity"}`; mode picker if f&1 (`available_modes`) → `set_mode {"mode"}` |
| `media_player` | `media_title` when playing/paused, else the state label (Off, Idle, On, Standby, Buffering) | playing | playing/paused → `media_play_pause`; off with f&128 → `turn_on`; else opens the sheet | title + `media_artist` lines; Previous / Play-pause / Next (f&16, f&1 or f&16384, f&32); volume slider 0–100 if f&4 → `volume_set {"volume_level": v/100}`; mute switch if f&8 → `volume_mute {"is_volume_muted"}`; power switch if f&128 or f&256 → `turn_on` / `turn_off`; source picker if f&2048 (`source_list`) → `select_source {"source"}` |
| `vacuum` | state label (Docked, Cleaning, Returning, Paused, Idle, Error) | cleaning | cleaning → `pause` if f&4, else `return_to_base`; otherwise `start` if f&8192 | Start (f&8192) / Pause (f&4) / Return home (f&16) / Locate (f&512) → `start` / `pause` / `return_to_base` / `locate`; fan speed picker if f&32 (`fan_speed_list`) → `set_fan_speed {"fan_speed"}` |
| `lawn_mower` | Docked / Mowing / Paused / Returning / Error | mowing | mowing → `pause` if f&2; otherwise `start_mowing` if f&1 | Start (f&1) / Pause (f&2) / Dock (f&4) → `start_mowing` / `pause` / `dock` |
| `alarm_control_panel` | Disarmed / Armed home / Armed away / Armed night / Armed vacation / Armed custom / Arming / Pending / Triggered / Disarming | any armed state, triggered (red) | opens the sheet (never acts) | code field when `code_format` is set (number pad for `"number"`); action buttons Arm home (f&1), Arm away (f&2), Arm night (f&4), Arm vacation (f&32), and Disarm when not disarmed → `alarm_arm_home` / `alarm_arm_away` / `alarm_arm_night` / `alarm_arm_vacation` / `alarm_disarm`, with `{"code"}` when a code was typed. Disarm needs the code when `code_format` is set; with no code, Disarm asks "Disarm <name>?" first (like unlock). Arming needs the code only when `code_arm_required`. The code is never stored |
| `number`, `input_number` | value + ` ` + `unit_of_measurement` | never | opens the sheet | slider `min`…`max`, step `step` → `set_value {"value"}` |
| `select`, `input_select` | current option | never | opens a menu of `options` (no sheet) | → `select_option {"option"}` |
| `sensor` | numbers rounded to the registry's display precision (`dp` in `list_for_display`), else as sent, + ` ` + `unit_of_measurement`; other states as sent | never | none | none |
| `binary_sensor` | by `device_class`: door, window, opening, garage_door → Open / Closed; motion, occupancy, presence → Detected / Clear; moisture → Wet / Dry; smoke, gas, carbon_monoxide, problem, safety, tamper → Detected / OK; lock → Unlocked / Locked; battery → Low / OK; connectivity → Connected / Disconnected; else On / Off | never | none | none |
| `weather` | condition label ("partlycloudy" → "Partly cloudy", "clear-night" → "Clear night", else capitalized) + ` · ` + `temperature` + `temperature_unit` | never | none | none |

State labels are the state with `_` (and, for weather, `-`) → space, first letter capitalized, unless given above.
Numbers show without a trailing `.0` ("42", "0.42"); temperatures carry `temperature_unit` after a space when present.
Mode pickers (hvac, operation) show labels; the other pickers (preset, fan, source, fan speed, select options) show
the raw strings. A vacuum or mower tap whose action's feature bit is missing opens the sheet. A stepper whose target
or bounds are missing is left out. With a `code_format`, Disarm (and arming when `code_arm_required`) stays disabled
until a code is typed; the typed code is cleared after each send; a wrong code shows the server's error over the sheet.
Picking a select option or a mode updates the tile at once (optimistic). If one area holds several hidden `onvif`
cameras, the lowest entity id moves. Icons: one plain glyph per
domain (binary sensors and sensors may pick by `device_class` where a glyph exists; no icon library).

- Optimistic update: flip `s` locally at once; if the server's state hasn't confirmed within 5 s (or the call fails),
  put back the last server state.

## Cameras screen

- Bottom tabs "Home" and "Cameras" (the Cameras tab only when there is at least one camera).
- A vertical list of 16:9 cards, one per camera, name under each. Cards on screen play live, muted, at once:
  - if `camera/capabilities` lists `hls`: `camera/stream` → play the HLS URL (iOS `AVPlayer`; Android ExoPlayer
    `HlsMediaSource`, low-latency live config, target offset ~2 s). Home Assistant serves low-latency HLS (H.264,
    1 s parts), so first frame should be ~1–2 s. While waiting, show the snapshot poster (below) or a dark placeholder
    with a spinner. On a playback error request a new stream URL once, then show "Stream unavailable". If
    `camera/stream` itself fails (the demo's cameras list `hls` but answer `start_stream_failed`), fall back to the
    snapshot refresh below.
  - otherwise: refresh the snapshot every 1 s.
  - Socket drop and reconnect: a stream that is playing keeps playing through a drop (HLS is plain HTTP), and so does
    the snapshot refresh of a card without a stream. When the socket is Live again, every card that isn't playing a
    stream (snapshots only, still loading, stalled, or "Stream unavailable") asks for a stream again, with its one
    retry restored. Coming back to the foreground does the same; in the background nothing plays.
  - Snapshot: `<base>` + `attributes.entity_picture` (it carries a `token=` query; no auth header). It may answer 500
    (some cameras can't make stills): then there's no poster.
- Cards scrolled off screen stop their player. `unavailable` camera: dimmed card "Unavailable", no player.
- Tap a card → full-screen live view of that camera (black background, aspect-fit, pinch to zoom, rotates to landscape,
  close button / back). Same player logic. (iOS allows landscape app-wide, so Home and Cameras rotate too.)
- Pan / tilt (full-screen view only): a camera can move when its registry platform (`pl` in `list_for_display`) is
  `onvif`, or when it is the only shown camera in its area and that area holds a hidden (`hb`) `onvif` camera. The
  second case is how a real home does it: Home Assistant's ONVIF stream can fail (a Tapo C210 whose password has
  special characters is refused by its RTSP server) while another integration streams the same camera fine, so the
  ONVIF camera is kept hidden and only moves it. A movable camera shows four arrow buttons (a translucent pad in the
  bottom corner, 44 pt/dp targets). Each tap sends one nudge to the `onvif` entity:
  `onvif.ptz {"pan":"LEFT"|"RIGHT"}` or `{"tilt":"UP"|"DOWN"}` with `"move_mode":"ContinuousMove","speed":0.5,
  "continuous_duration":1`. Tap only, no hold: the picture lags ~2 s, so holding overshoots. RelativeMove is not used:
  the C210 rejects it. No zoom buttons (pinch is the zoom).

## Settings

- Server URL, signed-in user name (`auth/current_user`), app version, "Sign out". Nothing else.

## Tests and checks

- Unit tests (pure logic, no network): applying `subscribe_entities` events (a/c/r merging), building the Home model
  (domain filter, hidden/category skip, area resolution entity→device→Other, readings only with an area and a state,
  controls before readings, prefix stripping, sort), state texts for the table above, tap decisions (lock, vacuum,
  media player, alarm never acting), the pan/tilt camera rule (own `onvif`; hidden `onvif` in the area of the only
  shown camera; two shown cameras in that area → none), token-needs-refresh decision. Android JUnit
  (`testDebugUnitTest`), iOS XCTest target `HomestillTests`.
- Control testing happens only against the throwaway demo server (`tools/demo-ha.sh`: Docker Home Assistant with the
  `demo` integration on :8124, user `demo` / `demo-pass`; emulator uses `http://10.0.2.2:8124`). Its rooms hold one of
  most domains above, and a stub `onvif` integration adds `camera.gate_camera` (Garden) whose `onvif.ptz` service
  stores the last call's data in the camera's `last_ptz` attribute. The developer's real home server
  holds real door locks and lights people are using: sign in, look, and watch the
  cameras, but never call a service on it from tests.

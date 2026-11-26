#!/bin/sh
# Throwaway Home Assistant with the `demo` integration (lights, switches, locks, covers, fans, cameras, areas) for testing
# controls without touching a real home. http://127.0.0.1:8124 (emulator: http://10.0.2.2:8124), user demo / demo-pass.
# `tools/demo-ha.sh stop` removes it.
# Never use the stock demo cameras in public screenshots: they show frames from a copyrighted cartoon. The site's shots
# (docs/cameras.webp, 2026-11-25) swapped them for public-domain photos by patching components/demo/camera.py in the container.
set -e
name=homestill-demo-ha
docker rm -f $name >/dev/null 2>&1 || true
[ "$1" = stop ] && exit 0
dir="${TMPDIR:-/tmp}/$name"
rm -rf "$dir" && mkdir -p "$dir/custom_components/onvif"
printf 'default_config:\ndemo:\nonvif:\n' > "$dir/configuration.yaml"
# A stand-in for the ONVIF integration (the demo has no pan/tilt camera): camera.gate_camera (platform onvif) and an
# onvif.ptz entity service that keeps the last call's data in the camera's `last_ptz` attribute and draws it in the image.
echo '{"domain":"onvif","name":"ONVIF stub","version":"0.0.1","documentation":"","codeowners":[],"requirements":[],"iot_class":"local_push","dependencies":["camera"]}' \
  > "$dir/custom_components/onvif/manifest.json"
cat > "$dir/custom_components/onvif/__init__.py" <<'EOF'
from homeassistant.helpers.discovery import async_load_platform
async def async_setup(hass, config):
    hass.async_create_task(async_load_platform(hass, "camera", "onvif", {}, config))
    return True
EOF
cat > "$dir/custom_components/onvif/camera.py" <<'EOF'
import io
import voluptuous as vol
from PIL import Image, ImageDraw
from homeassistant.components.camera import Camera
from homeassistant.helpers import entity_platform

async def async_setup_platform(hass, config, add, discovery_info=None):
    add([Gate()])
    entity_platform.async_get_current_platform().async_register_entity_service(
        "ptz", {vol.Optional(k): object for k in ("pan", "tilt", "zoom", "distance", "speed", "continuous_duration", "move_mode", "preset")}, "async_ptz")

class Gate(Camera):
    _attr_name = "Gate camera"
    _attr_unique_id = "stub_gate_camera"
    last = None
    @property
    def extra_state_attributes(self): return {"last_ptz": self.last}
    async def async_ptz(self, **kw):
        self.last = kw; self.async_write_ha_state()
    async def async_camera_image(self, width=None, height=None):
        im = Image.new("RGB", (640, 360), (40, 90, 120)); ImageDraw.Draw(im).text((20, 20), "last ptz: %s" % self.last, fill="white")
        b = io.BytesIO(); im.save(b, "JPEG"); return b.getvalue()
EOF
docker run -d --name $name -p 8124:8123 -v "$dir:/config" ghcr.io/home-assistant/home-assistant:2026.11.3 >/dev/null
until curl -sf http://127.0.0.1:8124/api/onboarding >/dev/null; do sleep 2; done
curl -sf -X POST http://127.0.0.1:8124/api/onboarding/users -H 'content-type: application/json' \
  -d '{"client_id":"http://127.0.0.1:8124/","name":"Demo","username":"demo","password":"demo-pass","language":"en"}' >/dev/null
sleep 10 # the demo integration finishes loading after onboarding opens
# The demo's entities have no area: put some in rooms (and hide one) so Home's sections can be checked.
node --input-type=module -e '
const B = "http://127.0.0.1:8124", CID = B + "/", j = async (p, b) => (await fetch(B + p, { method: "POST", body: JSON.stringify(b) })).json()
let f = await j("/auth/login_flow", { client_id: CID, handler: ["homeassistant", null], redirect_uri: CID })
f = await j("/auth/login_flow/" + f.flow_id, { client_id: CID, username: "demo", password: "demo-pass" })
const t = await (await fetch(B + "/auth/token", { method: "POST", body: new URLSearchParams({ grant_type: "authorization_code", code: f.result, client_id: CID }) })).json()
const rooms = { living_room: ["light.living_room_rgbww_lights", "light.ceiling_lights", "fan.living_room_fan", "cover.living_room_window", "switch.decorative_lights",
    "climate.hvac", "number.volume", "select.speed", "sensor.outside_humidity"],
  kitchen: ["light.kitchen_lights", "cover.kitchen_window", "water_heater.demo_water_heater", "binary_sensor.basement_floor_wet"],
  bedroom: ["light.bed_light", "switch.ac", "fan.ceiling_fan", "climate.heatpump"],
  garden: ["valve.front_garden", "valve.back_garden", "lawn_mower.my_lawn_mower", "binary_sensor.movement_backyard", "sensor.outside_temperature", "weather.demo_weather_south", "camera.gate_camera"],
  hall: ["alarm_control_panel.security", "vacuum.demo_vacuum_0_ground_floor"] }
const ws = new WebSocket(B.replace("http", "ws") + "/api/websocket"); let id = 0; const pend = {}
const call = (m) => new Promise((res) => { pend[m.id = ++id] = res; ws.send(JSON.stringify(m)) })
ws.onmessage = async (e) => { const m = JSON.parse(e.data)
  if (m.type === "auth_required") return ws.send(JSON.stringify({ type: "auth", access_token: t.access_token }))
  if (m.type === "result") return pend[m.id](m)
  if (m.type !== "auth_ok") return
  const dev = Object.fromEntries((await call({ type: "config/entity_registry/list_for_display" })).result.entities.map((x) => [x.ei, x.di]))
  const r = [await call({ type: "config/entity_registry/update", entity_id: "fan.preset_only_limited_fan", hidden_by: "user" }),
    await call({ type: "config/area_registry/create", name: "Garden" }), await call({ type: "config/area_registry/create", name: "Hall" })]
  for (const [area_id, ids] of Object.entries(rooms)) for (const entity_id of ids) r.push(await call(dev[entity_id]
    ? { type: "config/device_registry/update", device_id: dev[entity_id], area_id } : { type: "config/entity_registry/update", entity_id, area_id }))
  for (const x of r) if (!x.success) console.error(JSON.stringify(x.error))
  process.exit(0) }'
echo "Demo Home Assistant on http://127.0.0.1:8124 (demo / demo-pass)"

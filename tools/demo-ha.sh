#!/bin/sh
# Throwaway Home Assistant with the `demo` integration (lights, switches, locks, covers, fans, cameras, areas) for testing
# controls without touching a real home. http://127.0.0.1:8124 (emulator: http://10.0.2.2:8124), user demo / demo-pass.
# `tools/demo-ha.sh stop` removes it.
set -e
name=roomwell-demo-ha
docker rm -f $name >/dev/null 2>&1 || true
[ "$1" = stop ] && exit 0
dir="${TMPDIR:-/tmp}/$name"
rm -rf "$dir" && mkdir -p "$dir"
printf 'default_config:\ndemo:\n' > "$dir/configuration.yaml"
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
const rooms = { living_room: ["light.living_room_rgbww_lights", "light.ceiling_lights", "fan.living_room_fan", "cover.living_room_window", "switch.decorative_lights"],
  kitchen: ["light.kitchen_lights", "cover.kitchen_window"], bedroom: ["light.bed_light", "switch.ac", "fan.ceiling_fan"] }
const ws = new WebSocket(B.replace("http", "ws") + "/api/websocket"); let id = 0; const pend = {}
const call = (m) => new Promise((res) => { pend[m.id = ++id] = res; ws.send(JSON.stringify(m)) })
ws.onmessage = async (e) => { const m = JSON.parse(e.data)
  if (m.type === "auth_required") return ws.send(JSON.stringify({ type: "auth", access_token: t.access_token }))
  if (m.type === "result") return pend[m.id](m)
  if (m.type !== "auth_ok") return
  const dev = Object.fromEntries((await call({ type: "config/entity_registry/list_for_display" })).result.entities.map((x) => [x.ei, x.di]))
  const r = [await call({ type: "config/entity_registry/update", entity_id: "fan.preset_only_limited_fan", hidden_by: "user" })]
  for (const [area_id, ids] of Object.entries(rooms)) for (const entity_id of ids) r.push(await call(dev[entity_id]
    ? { type: "config/device_registry/update", device_id: dev[entity_id], area_id } : { type: "config/entity_registry/update", entity_id, area_id }))
  for (const x of r) if (!x.success) console.error(JSON.stringify(x.error))
  process.exit(0) }'
echo "Demo Home Assistant on http://127.0.0.1:8124 (demo / demo-pass)"

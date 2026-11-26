"""Onboard the fresh Home Assistant on 127.0.0.1:8123 like tools/demo-ha.sh: an owner with a throwaway password, rooms
for the demo's entities, one hidden fan, and the public reviewer login (a plain user, not an admin).
`setup.py check` instead exits non-zero unless the reviewer login still works (start.sh resets the server then)."""
import json, sys, urllib.request

B = "http://127.0.0.1:8123"
CID = B + "/"
REVIEWER = ("reviewer", "homestill-review-2026")

if sys.argv[1:] == ["check"]:
    def post(path, body):
        return json.load(urllib.request.urlopen(urllib.request.Request(B + path, json.dumps(body).encode()), timeout=20))
    f = post("/auth/login_flow", {"client_id": CID, "handler": ["homeassistant", None], "redirect_uri": CID})
    f = post("/auth/login_flow/" + f["flow_id"], {"client_id": CID, "username": REVIEWER[0], "password": REVIEWER[1]})
    sys.exit(f["type"] != "create_entry")

import asyncio, secrets
import aiohttp
ROOMS = {
    "living_room": ["light.living_room_rgbww_lights", "light.ceiling_lights", "fan.living_room_fan", "cover.living_room_window",
                    "switch.decorative_lights", "climate.hvac", "number.volume", "select.speed", "sensor.outside_humidity"],
    "kitchen": ["light.kitchen_lights", "cover.kitchen_window", "water_heater.demo_water_heater", "binary_sensor.basement_floor_wet"],
    "bedroom": ["light.bed_light", "switch.ac", "fan.ceiling_fan", "climate.heatpump"],
    "garden": ["valve.front_garden", "valve.back_garden", "lawn_mower.my_lawn_mower", "binary_sensor.movement_backyard",
               "sensor.outside_temperature", "weather.demo_weather_south", "camera.gate_camera"],
    "hall": ["alarm_control_panel.security", "vacuum.demo_vacuum_0_ground_floor"],
}


async def main():
    async with aiohttp.ClientSession() as s:
        while True:
            try:
                async with s.get(B + "/api/onboarding") as r:
                    if r.status == 200: break
            except aiohttp.ClientError:
                pass
            await asyncio.sleep(2)
        async with s.post(B + "/api/onboarding/users", json={"client_id": CID, "name": "Owner", "username": "owner",
                          "password": secrets.token_urlsafe(24), "language": "en"}) as r:
            code = (await r.json())["auth_code"]
        async with s.post(B + "/auth/token", data={"grant_type": "authorization_code", "code": code, "client_id": CID}) as r:
            token = (await r.json())["access_token"]
        auth = {"Authorization": "Bearer " + token}
        for step, body in (("core_config", {}), ("analytics", {}), ("integration", {"client_id": CID, "redirect_uri": CID})):
            async with s.post(f"{B}/api/onboarding/{step}", json=body, headers=auth) as r:
                if r.status != 200: print("onboarding", step, r.status, await r.text(), file=sys.stderr)

        async with s.ws_connect(B + "/api/websocket") as ws:
            await ws.receive_json()
            await ws.send_json({"type": "auth", "access_token": token})
            await ws.receive_json()
            n = 0

            async def call(**m):
                nonlocal n
                n += 1
                await ws.send_json({**m, "id": n})
                while True:
                    r = await ws.receive_json()
                    if r.get("id") == n: return r

            while True:  # the demo integration finishes loading after onboarding opens
                ents = (await call(type="config/entity_registry/list_for_display"))["result"]["entities"]
                dev = {e["ei"]: e.get("di") for e in ents}
                if all(i in dev for ids in ROOMS.values() for i in ids): break
                await asyncio.sleep(2)
            res = [await call(type="config/entity_registry/update", entity_id="fan.preset_only_limited_fan", hidden_by="user"),
                   await call(type="config/area_registry/create", name="Garden"),
                   await call(type="config/area_registry/create", name="Hall")]
            for area_id, ids in ROOMS.items():
                for i in ids:
                    res.append(await call(type="config/device_registry/update", device_id=dev[i], area_id=area_id) if dev[i]
                               else await call(type="config/entity_registry/update", entity_id=i, area_id=area_id))
            user = await call(type="config/auth/create", name="Reviewer", group_ids=["system-users"], local_only=False)
            res += [user, await call(type="config/auth_provider/homeassistant/create", user_id=user["result"]["user"]["id"],
                                     username=REVIEWER[0], password=REVIEWER[1])]
            bad = [r["error"] for r in res if not r.get("success")]
            if bad: sys.exit(f"setup failed: {bad}")


asyncio.run(main())

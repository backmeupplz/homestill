# A stand-in for the ONVIF integration (the demo has no pan/tilt camera), like tools/demo-ha.sh's: camera.gate_camera
# (platform onvif) and an onvif.ptz entity service that keeps the last call's data in the `last_ptz` attribute. Here the
# image is a 1280x720 window over a bigger public-domain photo that each pan/tilt call moves, so the arrows visibly work.
import io
import voluptuous as vol
from PIL import Image
from homeassistant.components.camera import Camera
from homeassistant.helpers import entity_platform

PHOTO = Image.open("/demo/cams/gate.jpg").convert("RGB")
W, H, STEP = 1280, 720, 80
MOVES = {"LEFT": (-STEP, 0), "RIGHT": (STEP, 0), "UP": (0, -STEP), "DOWN": (0, STEP)}

async def async_setup_platform(hass, config, add, discovery_info=None):
    add([Gate()])
    entity_platform.async_get_current_platform().async_register_entity_service(
        "ptz", {vol.Optional(k): object for k in ("pan", "tilt", "zoom", "distance", "speed", "continuous_duration", "move_mode", "preset")}, "async_ptz")

class Gate(Camera):
    _attr_name = "Gate camera"
    _attr_unique_id = "stub_gate_camera"
    content_type = "image/jpeg"
    last = None
    x, y = (PHOTO.width - W) // 2, 300
    @property
    def extra_state_attributes(self): return {"last_ptz": self.last}
    async def async_ptz(self, **kw):
        for k in ("pan", "tilt"):
            dx, dy = MOVES.get(kw.get(k), (0, 0))
            self.x = min(max(self.x + dx, 0), PHOTO.width - W)
            self.y = min(max(self.y + dy, 0), PHOTO.height - H)
        self.last = kw; self.async_write_ha_state()
    async def async_camera_image(self, width=None, height=None):
        b = io.BytesIO(); PHOTO.crop((self.x, self.y, self.x + W, self.y + H)).save(b, "JPEG", quality=80); return b.getvalue()

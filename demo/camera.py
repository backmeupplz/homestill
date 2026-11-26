"""Demo camera platform, patched for the Homestill reviewer server: each camera shows one public-domain photo
(demo/SOURCES.md) instead of the stock frames, which come from a copyrighted cartoon."""

from pathlib import Path
from typing import override

from homeassistant.components.camera import Camera, CameraEntityFeature
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

PHOTOS = Path("/demo/cams")


async def async_setup_entry(
    hass: HomeAssistant,
    config_entry: ConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    """Set up the Demo config entry."""
    async_add_entities(
        [
            DemoCamera("Driveway", "driveway"),
            DemoCamera("Backyard", "backyard"),
            DemoCameraWithoutStream("Living room", "living_room"),
        ]
    )


class DemoCamera(Camera):
    """The representation of a Demo camera."""

    _attr_is_streaming = True
    _attr_motion_detection_enabled = False
    _attr_supported_features = CameraEntityFeature.ON_OFF | CameraEntityFeature.STREAM
    content_type = "image/jpeg"

    def __init__(self, name: str, photo: str) -> None:
        """Initialize demo camera component."""
        super().__init__()
        self._attr_name = name
        self._attr_unique_id = f"homestill_demo_{photo}"
        self.photo = PHOTOS / f"{photo}.jpg"

    @override
    async def async_camera_image(
        self, width: int | None = None, height: int | None = None
    ) -> bytes:
        """Return the photo."""
        return await self.hass.async_add_executor_job(self.photo.read_bytes)

    @override
    async def async_enable_motion_detection(self) -> None:
        """Enable the Motion detection in base station (Arm)."""
        self._attr_motion_detection_enabled = True
        self.async_write_ha_state()

    @override
    async def async_disable_motion_detection(self) -> None:
        """Disable the motion detection in base station (Disarm)."""
        self._attr_motion_detection_enabled = False
        self.async_write_ha_state()

    @override
    async def async_turn_off(self) -> None:
        """Turn off camera."""
        self._attr_is_streaming = False
        self._attr_is_on = False
        self.async_write_ha_state()

    @override
    async def async_turn_on(self) -> None:
        """Turn on camera."""
        self._attr_is_streaming = True
        self._attr_is_on = True
        self.async_write_ha_state()


class DemoCameraWithoutStream(DemoCamera):
    """The representation of a Demo camera without stream."""

    _attr_supported_features = CameraEntityFeature.ON_OFF

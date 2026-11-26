from homeassistant.helpers.discovery import async_load_platform
async def async_setup(hass, config):
    hass.async_create_task(async_load_platform(hass, "camera", "onvif", {}, config))
    return True

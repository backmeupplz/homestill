#!/bin/sh
# Reviewer demo (https://demo.homestill.app, reviewer / homestill-review-2026, public on purpose). Every start wipes
# /config and onboards again, so nothing a reviewer changes survives a restart. The container exits after 24 h, or
# within a minute once the reviewer login stops working (a reviewer can change its password or turn on 2FA), and
# Docker's unless-stopped restart policy, which Tugport sets on every replica, starts it fresh: that is the reset.
set -e
cd /
rm -rf /config
mkdir -p /config/custom_components /config/.storage
cp -r /demo/onvif /config/custom_components/
printf 'default_config:\ndemo:\nonvif:\n' > /config/configuration.yaml
# HTTP settings live in .storage/http since 2026.11 (yaml ones become a "pending" trial that reverts and restarts HA
# after 5 minutes), so write them there as the confirmed config. Trust the reverse proxy's X-Forwarded-For.
http() {
  cat > /config/.storage/http <<EOF
{"version": 3, "minor_version": 1, "key": "http", "data": {"pending": null, "yaml_migration_done": true, "stable": {
  "server_host": [$1], "server_port": 8123, "use_x_forwarded_for": true,
  "trusted_proxies": ["127.0.0.1/32", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"],
  "cors_allowed_origins": ["https://cast.home-assistant.io"], "login_attempts_threshold": -1, "ip_ban_enabled": true,
  "ssl_profile": "intermediate_v6", "use_x_frame_options": true, "created_at": "2026-11-25T00:00:00+00:00",
  "error": null, "error_message": null}}}
EOF
}
# Onboard while listening on loopback only, so nobody outside can claim the owner account first.
http '"127.0.0.1"'
python3 -P -m homeassistant --config /config &
python3 -P /demo/setup.py
kill $! && wait $! || true
http '"0.0.0.0", "::"'
python3 -P -m homeassistant --config /config &
ha=$!
end=$(($(date +%s) + 86400))
sleep 60
while [ "$(date +%s)" -lt $end ] && kill -0 $ha && python3 -P /demo/setup.py check; do sleep 60; done
kill $ha || true

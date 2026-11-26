#!/bin/sh
# Reviewer demo (https://demo.homestill.app, reviewer / homestill-review-2026, public on purpose). Every start wipes
# /config and onboards again, so nothing a reviewer changes survives a restart. The container exits after 24 h, or
# within a minute once the reviewer login stops working (a reviewer can change its password or turn on 2FA), and
# Docker's unless-stopped restart policy, which Tugport sets on every replica, starts it fresh: that is the reset.
set -e
cd /
rm -rf /config
mkdir -p /config/custom_components
cp -r /demo/onvif /config/custom_components/
http='http:\n  use_x_forwarded_for: true\n  trusted_proxies: [127.0.0.1, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16]\n'
# Onboard while listening on loopback only, so nobody outside can claim the owner account first.
printf "default_config:\ndemo:\nonvif:\n$http  server_host: 127.0.0.1\n" > /config/configuration.yaml
python3 -P -m homeassistant --config /config &
python3 -P /demo/setup.py
kill $! && wait $! || true
rm -f /config/.storage/http # HA copies the yaml http settings here once; drop them so the new ones apply
printf "default_config:\ndemo:\nonvif:\n$http" > /config/configuration.yaml
python3 -P -m homeassistant --config /config &
ha=$!
end=$(($(date +%s) + 86400))
sleep 60
while [ "$(date +%s)" -lt $end ] && kill -0 $ha && python3 -P /demo/setup.py check; do sleep 60; done
kill $ha || true

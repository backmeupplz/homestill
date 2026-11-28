FROM ghcr.io/home-assistant/home-assistant:2026.11.3@sha256:24e541ddae5818bf8eb27898b9ba00d0c344a655aa5097e9e9bd4b19356be847
# The stock demo cameras show frames from a copyrighted cartoon: drop them and serve public-domain photos instead.
RUN rm /usr/src/homeassistant/homeassistant/components/demo/demo_*
COPY camera.py /usr/src/homeassistant/homeassistant/components/demo/camera.py
COPY . /demo
ENV PYTHONMALLOC=mimalloc
ENTRYPOINT ["/bin/sh", "/demo/start.sh"]

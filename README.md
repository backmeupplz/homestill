# Roomwell

A small, fast, native Home Assistant client for Android (Kotlin, Jetpack Compose) and iPhone (SwiftUI). It does two
things: control your devices and show your cameras live. No dashboards, no history, no settings editor.

- What the apps do and how they talk to Home Assistant: [SPEC.md](SPEC.md).
- Test server: `tools/demo-ha.sh` starts a throwaway Home Assistant with demo devices on http://127.0.0.1:8124
  (user `demo`, password `demo-pass`); `tools/demo-ha.sh stop` removes it.

MIT licensed.

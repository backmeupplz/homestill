# Homestill for agents

- SPEC.md is the contract for both apps; change it in the same commit when behavior changes.
- Android lives in `app/` (package com.borodutch.homestill), iPhone in `ios/`. Sister apps with the patterns we copy:
  `~/code/spinwell-main` (closest) and `~/code/absplus`.
- Context rules: grep, then read line ranges; never cat whole big files or full build logs (`| tail -40`, `-quiet`).
  Screenshots only to check a screen you changed, resized small (`sips -Z 800`), not after every step.
- Android: `JAVA_HOME=/opt/homebrew/opt/openjdk@21 ANDROID_HOME=/opt/homebrew/share/android-commandlinetools ./gradlew testDebugUnitTest assembleDebug`.
- iOS: `xcodebuild test -project ios/Homestill.xcodeproj -scheme Homestill -destination "platform=iOS Simulator,name=iPhone 17 Pro"`.
- Test server: `tools/demo-ha.sh` (Docker, demo / demo-pass on :8124). The real home server has real door locks: never
  call a service on it from tests (SPEC "Tests and checks").

# RCPU Mobile Miner

A small Flutter Android app that mines RCPU (RandomX) on the phone, pointing at the
official pool by default.

## What it does

- Bundles the arm64 `minerd-rcpu` miner as a native library and runs it as a child
  process (Android only allows executing binaries from the read-only lib directory,
  so it ships as `jniLibs/arm64-v8a/libminerdrcpu.so`).
- Settings (wallet, pool, threads, language) are stored in a JSON file — no plugins.
- Live hashrate / accepted-rejected counters parsed from the miner output, plus a
  scrolling log view.
- Chinese and English UI, switchable with the button in the app bar and persisted.

## Defaults

- Pool: `stratum+tcp://207.57.129.188:3334` (PPLNS 0.5%)
- Threads: 4
- Fee: none

## Build

```bash
flutter pub get
flutter build apk --release --target-platform android-arm64
```

Requires Android SDK 34 + build-tools 34. Sign the APK afterwards:

```bash
zipalign -p -f 4 app-release.apk aligned.apk
apksigner sign --ks your.jks --out RCPU-Miner.apk aligned.apk
```

## Notes

Phone CPUs are slow at RandomX (roughly 100–500 H/s) and will get warm; the app is
meant for testing and demonstrating the network, not for serious mining.

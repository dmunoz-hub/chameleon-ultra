# Chameleon (Android)

Native Android app for the Chameleon Ultra — Kotlin + Jetpack Compose + Android `BluetoothGatt`,
with the firmware's Crypto1 key-recovery solvers compiled via the **NDK** (same C code as iOS).
Feature parity with the iOS and web apps:

- Connect over BLE (scan by NUS service UUID), device info
- LF: EM410x → T5577 clone + auto-verify
- HF: 14a scan + classify, MIFARE block read/write, dictionary **Find key**
- Magic UID / block-0 write (Gen1a backdoor + Gen2)
- **Key recovery**: nested / staticnested / darkside, run natively on-device (NDK)

A debug-signed APK installs by sideload and **doesn't expire** (unlike free-provisioned iOS).

## Getting the APK (GitHub Actions)

Pushing this repo to GitHub triggers `.github/workflows/android.yml`, which installs the Android
SDK + NDK + CMake, builds a debug APK, and uploads it as the **`chameleon-debug-apk`** artifact.

1. Push to GitHub (see repo root).
2. Open the repo's **Actions** tab → the latest **Android APK** run.
3. Download the **chameleon-debug-apk** artifact (a zip containing `app-debug.apk`).
4. On the phone: enable **Install unknown apps** for your browser/file manager, open the APK, install.
5. Launch, grant the **Nearby devices / Bluetooth** permission, and Connect.

Re-run anytime from the Actions tab (**Run workflow**) if you change the code.

## Building locally (optional)

Needs Android SDK + NDK 26.1.10909125 + CMake 3.22.1. Then:

```bash
cd android
./gradlew assembleDebug   # or: gradle assembleDebug
# → app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## Layout

- `app/src/main/java/com/demomdl/chameleon/` — Kotlin: `Protocol`, `ChameleonBle`, `ChameleonController`, `KeyRecovery` (JNI), `MainActivity` (Compose UI)
- `app/src/main/cpp/` — the C solvers + `jni_bridge.c` + `CMakeLists.txt` (built to `libsolver.so`)

# Chameleon LF

A native iOS app (Swift + SwiftUI, Core Bluetooth) that drives a **Chameleon Ultra** over its
Nordic UART Service to clone LF and HF tags from one place — replacing the Chameleon Go + MTools
two-app workflow.

- **LF:** read EM410x (EM4100) → write to a blank T5577 → **auto-verify** by reading it back.
- **HF:** scan ISO 14443-A (UID / SAK / ATQA), classify the tag, read/write MIFARE Classic blocks,
  dictionary key recovery. Encrypted cards (DESFire / iCLASS SE / SEOS) are flagged *not clonable*.

Command IDs and the T5577 write payload are ported from the firmware's Python CLI
(`RfidResearchGroup/ChameleonUltra` → `software/script/chameleon_cmd.py`, `chameleon_enum.py`),
not guessed.

## Files

| File | Role |
|------|------|
| `project.yml` | XcodeGen project definition (reproducible from the CLI) |
| `ChameleonLF/Protocol.swift` | Frame build/parse, LRC, command IDs, response structs |
| `ChameleonLF/ChameleonBLE.swift` | Core Bluetooth transport: scan-by-service, connect, notify, write, frame buffer |
| `ChameleonLF/ChameleonController.swift` | High-level LF + HF commands |
| `ChameleonLF/ContentView.swift` | UI: Connect, Read/Write/Verify, HF scan, status log |
| `ChameleonLF/Info.plist` | Includes `NSBluetoothAlwaysUsageDescription` (required for BLE) |

## Build & install from the terminal

Everything runs in the terminal. **One** step needs the Xcode GUI, once: adding your Apple ID so a
free provisioning profile can be issued (`xcodebuild` cannot add an Apple ID account on its own).
After that, every build and install is CLI-only.

### 0. One-time: register your Apple ID (only GUI step, ever)

Open Xcode → **Settings → Accounts → +** → Apple ID, sign in, close Xcode. This just registers the
account; you never open the project in Xcode.

### 1. Regenerate the project (after any file change)

```bash
cd ~/Desktop/ChameleonLF
xcodegen generate
```

### 2. Find your Team ID

```bash
defaults read com.apple.dt.Xcode IDEProvisioningTeams
```

Look for the 10-character `teamID` (free accounts show `"teamType" = Individual`). Put it in
`project.yml` under `DEVELOPMENT_TEAM`, **or** pass it on the command line as shown below.

### 3. Device prep

- iPhone connected by cable, unlocked.
- **Settings → Privacy & Security → Developer Mode → On** (reboots once).
- If the Chameleon ever appears under **Settings → Bluetooth**, choose *Forget this device* — this
  app uses a plain GATT connection, not iOS pairing.

### 4. Build for the device

```bash
xcodebuild -scheme ChameleonLF -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  PRODUCT_BUNDLE_IDENTIFIER=com.YOURNAME.chameleonlf \
  build
```

Use a bundle id unique to you (free accounts reject already-used ids). The `.app` lands at:

```
build/Build/Products/Debug-iphoneos/ChameleonLF.app
```

### 5. Install to the iPhone

```bash
xcrun devicectl list devices                     # copy your device identifier
xcrun devicectl device install app \
  --device YOUR_DEVICE_ID \
  build/Build/Products/Debug-iphoneos/ChameleonLF.app
```

First launch: **Settings → General → VPN & Device Management → [your Apple ID] → Trust**.

> **Free Apple ID 7-day limit:** the signature expires after a week; rerun steps 4–5 to reinstall.
> A paid Apple Developer account removes the limit.

## Using it

1. **Connect** — scans by the NUS service UUID (not by name) and connects.
2. **LF clone:** present the source EM410x tag → **Read** → swap in a blank T5577 → **Write + Verify**.
   Verify re-scans the T5577 and shows PASS/FAIL — the automatic check that Chameleon Go lacks.
3. **HF:** **Scan** a 13.56 MHz card to see UID + type and whether it's clonable.

## The T5577 write-back fix

The EM410x→T5577 write uses the CLI's exact payload — the 5-byte ID plus the default T5577 key set
(`new_key = 20 20 66 66`, `old_keys = 51 24 36 48` / `19 92 04 27`) — so the config block (block 0)
is written with the correct EM4100 preset (Manchester, RF/64, 2 data blocks). That's what makes the
card readable back as an EM4100, which is the step that fails in Chameleon Go.

## Not yet wired up (next steps)

- HF magic-card (Gen1a / Gen2) block-0 / UID write for full MIFARE Classic clones.
- Nested / darkside key recovery (dictionary attack is implemented; the firmware commands
  `MF1_NESTED_ACQUIRE` / `MF1_DARKSIDE_ACQUIRE` are defined in `Protocol.swift` but not yet driven).

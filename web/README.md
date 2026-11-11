# Chameleon Web

A dependency-free browser controller for the Chameleon Ultra. Connects over **WebSerial (USB)** or
**Web Bluetooth (BLE)**, reads device info, scans HF (ISO 14443-A) and LF (EM410x) tags, and has a
raw-command console. Single file: `index.html`.

## Browser support (important)

- **Works:** Chrome, Edge, Opera on **desktop**; Chrome on **Android** (BLE only).
- **Does not work:** Safari, and **anything on iOS/iPadOS** — Apple ships neither WebSerial nor
  Web Bluetooth. (That's why the native iOS app exists.)
- Must be served from a **secure context**: `https://…` or `http://localhost`. The page detects
  this and shows a banner if USB/BLE are unavailable.

## Run locally

```bash
cd ~/Desktop/ChameleonLF/web
python3 -m http.server 8000
```

Open <http://localhost:8000> in Chrome or Edge (localhost counts as secure, so USB + BLE both work).

## Deploy to Vercel — yes, this works

The app is 100% client-side: the browser talks to the Chameleon directly and no server is involved,
so Vercel just serves the static file over HTTPS (which satisfies the secure-context requirement).

**Option A — CLI**

```bash
cd ~/Desktop/ChameleonLF/web
npx vercel            # first run links/creates the project
npx vercel --prod     # deploy to production
```

**Option B — Git/dashboard**

1. Put this `web/` folder in a Git repo (GitHub/GitLab/Bitbucket).
2. On vercel.com → **Add New Project** → import the repo.
3. Framework preset: **Other**. Root directory: `web` (if the repo has more than this folder).
   No build command, no install step — it's a static site.
4. Deploy. You get an `https://…vercel.app` URL that serves the page with a valid certificate, so
   WebSerial/WebBLE are enabled for desktop-Chromium visitors.

No `vercel.json` is required for a plain static page. Add one only if you later want custom headers
or routes.

## Notes / next steps

- LF is a full clone flow: **Scan EM410x → Write T5577 → Verify** (re-reads and compares), using
  the firmware CLI's default T5577 key set and EM4100 preset — same as the native iOS app.
- HF: scan + classify, **MIFARE Classic block read/write**, a dictionary **key-find** (auto-fills a
  working key), and **magic-card UID / block-0 write** for both **Gen2** (normal write) and **Gen1a**
  (backdoor unlock sequence via `hf14a_raw`). `Build block 0` computes UID·BCC·SAK·ATQA for you.
- **Nested key recovery** runs in-browser: the **Recover target key** button detects the tag PRNG,
  collects nonces on-device, and cracks the target key with the firmware's own `nested` /
  `staticnested` solver compiled to WebAssembly (see `../wasm/`), then verifies it on the card.
  The compiled `.wasm`/`.js` live in `web/wasm/` and are plain static files — commit them and Vercel
  serves them as-is (single-threaded build, so no special headers).
- **Darkside recovery** (no known key needed) is wired too: **Darkside recover** acquires
  repeatedly and intersects candidates in the `darkside` WASM until one verifies. Fails with
  `CANT_FIX_NT` on unpredictable-PRNG cards.
- Hardnested tags need the iOS app.
- The frame codec and command IDs are shared with the iOS app and verified by a unit test
  (frame build + chunked reassembly + status decode).

# WASM key-recovery solvers

Compiles the Chameleon firmware's **proven** Crypto1 key-recovery tools to WebAssembly so the web
app can crack MIFARE Classic keys in the browser — the same C code the official CLI shells out to,
not a reimplementation.

- `nested` — dynamic nested attack (weak-PRNG tags)
- `staticnested` — static nested attack (static-nonce tags)
- `darkside` — darkside attack (recovers a first key with no known key)

Sources in `src/` are copied verbatim from `RfidResearchGroup/ChameleonUltra` `software/src/`, plus
one added file: `src/pthread.h`, a synchronous shim so the nested solver builds **without** threads
(no SharedArrayBuffer, no COOP/COEP headers → serves from any static host).

## Build

Needs **emscripten**. One-time install:

```bash
git clone https://github.com/emscripten-core/emsdk.git ~/emsdk
cd ~/emsdk && ./emsdk install latest && ./emsdk activate latest
```

Then build:

```bash
source ~/emsdk/emsdk_env.sh
~/Desktop/ChameleonLF/wasm/build.sh
```

Artifacts land in `../web/wasm/{nested,staticnested,darkside}.{js,wasm}`, which the web app loads on
demand when you run **Recover key**.

## Tool interfaces (how the web app calls them)

Each is a `main()` that takes nonces as argv and prints `Key N... <12 hex>` lines.

- **nested**: `uid dist  nt nt_enc par  [nt nt_enc par …]`
  (uid + dist from `MF1_DETECT_NT_DIST`; triples from `MF1_NESTED_ACQUIRE`)
- **staticnested**: `uid type  nt nt_enc  [nt nt_enc …]`
  (uid + nonces from `MF1_STATIC_NESTED_ACQUIRE`; `type` = 0x60/0x61)
- **darkside**: `uid  nt ks_list par_list nr ar  [× N]` (from `MF1_DARKSIDE_ACQUIRE`)

The web app runs each as `await Module({ arguments:[…], print: capture })`, parses the key(s), and
verifies each with `MF1_AUTH_ONE_KEY_BLOCK` before accepting it.

## Deploy

The `.wasm`/`.js` are plain static files — commit `web/wasm/` and Vercel serves them as-is. Because
the build is single-threaded, **no special headers are required**.

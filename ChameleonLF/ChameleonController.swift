//  ChameleonController.swift
//  High-level commands: device info, LF (EM410x -> T5577 clone + verify), HF (14a).
//
//  Payload layouts ported from RfidResearchGroup/ChameleonUltra software/script/chameleon_cmd.py:
//    EM410X_WRITE_TO_T55XX: !5s4s8s  = id(5) | new_key(4) | old_keys(2 x 4)
//    EM410X_SCAN response:  !H5s     = type(2) | id(5)
//    HF14A_SCAN response:   uidlen(1)|uid|atqa(2)|sak(1)|atslen(1)|ats
//    MF1_READ_ONE_BLOCK:    !BB6s    = keyType(1) | block(1) | key(6)
//    MF1_WRITE_ONE_BLOCK:   !BB6s16s = keyType(1) | block(1) | key(6) | data(16)
//    MF1_CHECK_KEYS_ON_BLOCK: !BBB{n*6}s = block(1) | keyType(1) | nKeys(1) | keys

import Foundation
import Combine

struct HF14ATag {
    let uid: [UInt8]
    let atqa: [UInt8]
    let sak: UInt8
    let ats: [UInt8]

    /// Best-effort tag classification + whether an app can clone it.
    var kind: TagKind { TagKind.classify(sak: sak, atqa: atqa) }
}

enum TagKind {
    case ntagOrUltralight
    case mifareClassic1K
    case mifareClassic4K
    case iso14443_4   // DESFire / SmartMX / secure element
    case unknown

    var name: String {
        switch self {
        case .ntagOrUltralight: return "NTAG / MIFARE Ultralight"
        case .mifareClassic1K:  return "MIFARE Classic 1K"
        case .mifareClassic4K:  return "MIFARE Classic 4K"
        case .iso14443_4:       return "ISO 14443-4 (DESFire / secure)"
        case .unknown:          return "Unknown HF tag"
        }
    }

    /// Can this be cloned by an app at all (ignoring whether you have the keys)?
    var clonable: Bool {
        switch self {
        case .ntagOrUltralight, .mifareClassic1K, .mifareClassic4K: return true
        case .iso14443_4, .unknown: return false
        }
    }

    var note: String {
        switch self {
        case .ntagOrUltralight:
            return "Writable directly (no keys needed)."
        case .mifareClassic1K, .mifareClassic4K:
            return "Needs sector keys to read; needs a magic card (Gen1a/Gen2) to write a new UID."
        case .iso14443_4:
            return "Encrypted / mutual-auth. Not clonable by any app — don't try to write."
        case .unknown:
            return "Couldn't classify from SAK/ATQA."
        }
    }

    static func classify(sak: UInt8, atqa: [UInt8]) -> TagKind {
        // SAK bit 5 (0x20) set => ISO 14443-4 compliant (DESFire etc.)
        if sak & 0x20 != 0 { return .iso14443_4 }
        switch sak {
        case 0x00:          return .ntagOrUltralight   // Ultralight / NTAG
        case 0x08, 0x09:    return .mifareClassic1K
        case 0x18:          return .mifareClassic4K
        default:            return .unknown
        }
    }
}

struct SlotRow: Identifiable {
    let id: Int          // 0-based slot index
    let hfEnabled: Bool
    let lfEnabled: Bool
    let hfType: Int
    let lfType: Int
}

@MainActor
final class ChameleonController: ObservableObject {

    @Published var log: [String] = []
    @Published var isConnected = false
    @Published var busy = false
    @Published var lastReadId: [UInt8]? = nil          // last EM410x id read
    @Published var lastHFTag: HF14ATag? = nil
    @Published var deviceInfo: String = ""
    @Published var lastFoundKey: [UInt8]? = nil        // last recovered / found MIFARE key
    @Published var slots: [SlotRow] = []
    @Published var activeSlot: Int = 0

    let ble = ChameleonBLE()
    private var cancellables = Set<AnyCancellable>()

    // Default T5577 key set used by the CLI (verbatim from chameleon_cmd.py).
    static let t55NewKey: [UInt8]   = [0x20, 0x20, 0x66, 0x66]
    static let t55OldKeys: [[UInt8]] = [[0x51, 0x24, 0x36, 0x48], [0x19, 0x92, 0x04, 0x27]]

    // A small dictionary of well-known MIFARE Classic keys for the recover-keys flow.
    static let defaultMifareKeys: [[UInt8]] = [
        [0xFF,0xFF,0xFF,0xFF,0xFF,0xFF],
        [0x00,0x00,0x00,0x00,0x00,0x00],
        [0xA0,0xA1,0xA2,0xA3,0xA4,0xA5],
        [0xD3,0xF7,0xD3,0xF7,0xD3,0xF7],
        [0xB0,0xB1,0xB2,0xB3,0xB4,0xB5],
        [0x4D,0x3A,0x99,0xC3,0x51,0xDD],
        [0x1A,0x98,0x2C,0x7E,0x45,0x9A],
        [0xAA,0xBB,0xCC,0xDD,0xEE,0xFF],
        [0x71,0x4C,0x5C,0x88,0x6E,0x97],
        [0x58,0x7E,0xE5,0xF9,0x35,0x0F],
        [0xA0,0x47,0x8C,0xC3,0x90,0x91],
        [0x53,0x3C,0xB6,0xC7,0x23,0xF6],
        [0x8F,0xD0,0xA4,0xF2,0x56,0xE9],
    ]

    init() {
        ble.onLog = { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }
        ble.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] v in self?.isConnected = v }
            .store(in: &cancellables)
    }

    // MARK: - Logging

    func append(_ s: String) {
        log.append(s)
        if log.count > 600 { log.removeFirst(log.count - 600) }
    }
    private func line(_ s: String) { append(s) }

    private func run(_ title: String, _ body: @escaping () async throws -> Void) {
        guard !busy else { line("Busy — wait for the current step.") ; return }
        busy = true
        Task {
            do { try await body() }
            catch { line("\(title) error: \(error.localizedDescription)") }
            busy = false
        }
    }

    // MARK: - Connection + device info

    func connect() {
        run("Connect") {
            try await self.ble.connect()
            await self.readDeviceInfo()
        }
    }

    func disconnect() { ble.disconnect() }

    private func readDeviceInfo() async {
        do {
            var parts: [String] = []
            let ver = try await ble.send(.getAppVersion)
            if ver.data.count >= 2 { parts.append("fw \(ver.data[0]).\(ver.data[1])") }
            let chip = try await ble.send(.getDeviceChipId)
            if !chip.data.isEmpty { parts.append("chip \(ChameleonFrame.hex(chip.data))") }
            let bat = try await ble.send(.getBatteryInfo)
            if bat.data.count >= 3 {
                let mv = Int(bat.data[0]) << 8 | Int(bat.data[1])
                parts.append("battery \(bat.data[2])% (\(mv) mV)")
            }
            deviceInfo = parts.joined(separator: "  ·  ")
            line("Device: \(deviceInfo)")
        } catch {
            line("Device info unavailable: \(error.localizedDescription)")
        }
    }

    // MARK: - Device mode

    @discardableResult
    private func setReaderMode(_ reader: Bool) async throws -> Bool {
        // CHANGE_DEVICE_MODE payload is one byte: reader = 1, tag = 0.
        let resp = try await ble.send(.changeDeviceMode, data: [reader ? 1 : 0])
        return resp.genericOk
    }

    // MARK: - LF: EM410x -> T5577

    /// Read the EM410x tag on the antenna; returns the 5-byte ID.
    @discardableResult
    func readEM410x() async throws -> [UInt8]? {
        try await setReaderMode(true)
        let resp = try await ble.send(.em410xScan)
        guard resp.lfOk, resp.data.count >= 7 else {
            line("No EM410x tag found (\(resp.statusEnum.label)).")
            return nil
        }
        let id = Array(resp.data[2 ..< 7]) // skip 2-byte type prefix
        lastReadId = id
        line("EM410x ID: \(ChameleonFrame.hexSpaced(id))")
        return id
    }

    func readEM410xButton() {
        run("Read") { _ = try await self.readEM410x() }
    }

    /// Write a 5-byte EM410x ID onto a blank T5577, using the CLI's default EM4100 preset + keys.
    @discardableResult
    func writeEM410xToT55xx(id: [UInt8]) async throws -> Bool {
        guard id.count == 5 else { line("ID must be 5 bytes."); return false }
        try await setReaderMode(true)

        var payload: [UInt8] = []
        payload.append(contentsOf: id)                 // 5s
        payload.append(contentsOf: Self.t55NewKey)     // 4s new_key
        for k in Self.t55OldKeys { payload.append(contentsOf: k) } // 8s = 2 x 4s old keys

        let resp = try await ble.send(.em410xWriteToT55xx, data: payload, timeout: 8)
        if resp.lfOk {
            line("Write OK (EM4100 preset written to T5577).")
            return true
        }
        line("Write failed (\(resp.statusEnum.label)).")
        return false
    }

    func writeButton() {
        run("Write") {
            guard let id = self.lastReadId else { self.line("Read a tag first."); return }
            _ = try await self.writeEM410xToT55xx(id: id)
        }
    }

    /// Switch to reader mode, re-scan the (now written) T5577, compare to the expected ID.
    @discardableResult
    func verify(expected: [UInt8]) async throws -> Bool {
        line("Verifying — scanning the card back…")
        guard let read = try await readEM410x() else {
            line("Verify: FAIL ❌ (no tag detected)")
            return false
        }
        let ok = read == expected
        line(ok ? "Verify: PASS ✅" : "Verify: FAIL ❌ (read \(ChameleonFrame.hexSpaced(read)), expected \(ChameleonFrame.hexSpaced(expected)))")
        return ok
    }

    func verifyButton() {
        run("Verify") {
            guard let id = self.lastReadId else { self.line("Read/write a tag first."); return }
            _ = try await self.verify(expected: id)
        }
    }

    /// Full one-tap clone: read original, prompt handled in UI; here we just write + verify the last id.
    func cloneAndVerify() {
        run("Clone") {
            guard let id = self.lastReadId else { self.line("Read the source tag first."); return }
            let wrote = try await self.writeEM410xToT55xx(id: id)
            guard wrote else { return }
            _ = try await self.verify(expected: id)
        }
    }

    // MARK: - HF: ISO 14443-A

    @discardableResult
    func hf14aScan() async throws -> HF14ATag? {
        try await setReaderMode(true)
        let resp = try await ble.send(.hf14aScan)
        guard resp.hfOk, resp.data.count >= 1 else {
            line("No HF tag found (\(resp.statusEnum.label)).")
            return nil
        }
        let d = resp.data
        var o = 0
        let uidlen = Int(d[o]); o += 1
        guard d.count >= o + uidlen + 4 else { line("Malformed HF response."); return nil }
        let uid = Array(d[o ..< o + uidlen]); o += uidlen
        let atqa = Array(d[o ..< o + 2]); o += 2
        let sak = d[o]; o += 1
        let atslen = Int(d[o]); o += 1
        let ats = (atslen > 0 && d.count >= o + atslen) ? Array(d[o ..< o + atslen]) : []

        let tag = HF14ATag(uid: uid, atqa: atqa, sak: sak, ats: ats)
        lastHFTag = tag
        line("HF UID \(ChameleonFrame.hexSpaced(uid))  SAK \(ChameleonFrame.hex(sak))  ATQA \(ChameleonFrame.hexSpaced(atqa))")
        line("Type: \(tag.kind.name) — \(tag.kind.clonable ? "clonable" : "NOT clonable")")
        line(tag.kind.note)
        return tag
    }

    func hf14aScanButton() {
        run("HF scan") { _ = try await self.hf14aScan() }
    }

    func mfReadBlock(_ block: UInt8, key: [UInt8], keyType: MifareKeyType) async throws -> [UInt8]? {
        try await setReaderMode(true)
        var data: [UInt8] = [keyType.rawValue, block]
        data.append(contentsOf: key)
        let resp = try await ble.send(.mf1ReadOneBlock, data: data)
        guard resp.hfOk, resp.data.count == 16 else {
            line("Read block \(block) failed (\(resp.statusEnum.label)).")
            return nil
        }
        line("Block \(block): \(ChameleonFrame.hexSpaced(resp.data))")
        return resp.data
    }

    @discardableResult
    func mfWriteBlock(_ block: UInt8, data16: [UInt8], key: [UInt8], keyType: MifareKeyType) async throws -> Bool {
        guard data16.count == 16 else { line("Block data must be 16 bytes."); return false }
        try await setReaderMode(true)
        var data: [UInt8] = [keyType.rawValue, block]
        data.append(contentsOf: key)
        data.append(contentsOf: data16)
        let resp = try await ble.send(.mf1WriteOneBlock, data: data)
        if resp.hfOk { line("Wrote block \(block)."); return true }
        line("Write block \(block) failed (\(resp.statusEnum.label)).")
        return false
    }

    /// Try a key dictionary against one block; returns the first working key (and type), if any.
    func findKey(block: UInt8, keyType: MifareKeyType, keys: [[UInt8]]) async throws -> [UInt8]? {
        try await setReaderMode(true)
        // MF1_CHECK_KEYS_ON_BLOCK: block(1) | keyType(1) | nKeys(1) | keys...
        var data: [UInt8] = [block, keyType.rawValue, UInt8(min(keys.count, 83))]
        for k in keys.prefix(83) { data.append(contentsOf: k) }
        let resp = try await ble.send(.mf1CheckKeysOnBlock, data: data, timeout: 15)
        // Response (7 bytes): found(1) | key(6)
        if resp.data.count >= 7, resp.data[0] != 0 {
            let key = Array(resp.data[1 ..< 7])
            line("Found key \(keyType) for block \(block): \(ChameleonFrame.hex(key))")
            return key
        }
        return nil
    }

    /// Dictionary attack across sector trailers for both key types.
    func recoverKeys(sectors: Int = 16) {
        run("Recover keys") {
            try await self.setReaderMode(true)
            guard try await self.hf14aScan() != nil else { return }
            self.line("Trying \(Self.defaultMifareKeys.count)-key dictionary on \(sectors) sectors…")
            for sector in 0 ..< sectors {
                let trailer = UInt8(sector * 4 + 3)
                var found = false
                for kt in [MifareKeyType.keyA, .keyB] {
                    if let _ = try await self.findKey(block: trailer, keyType: kt, keys: Self.defaultMifareKeys) {
                        found = true
                    }
                }
                if !found { self.line("Sector \(sector): no dictionary key. Needs nested/darkside attack.") }
            }
            self.line("Dictionary pass done. Use Recover key (nested) or Darkside for the rest.")
        }
    }

    // MARK: - Button wrappers (MIFARE block + find key)

    func mfReadBlockButton(block: UInt8, key: [UInt8], keyType: MifareKeyType) {
        run("Read block") { _ = try await self.mfReadBlock(block, key: key, keyType: keyType) }
    }
    func mfWriteBlockButton(block: UInt8, data16: [UInt8], key: [UInt8], keyType: MifareKeyType) {
        run("Write block") { _ = try await self.mfWriteBlock(block, data16: data16, key: key, keyType: keyType) }
    }
    func findKeyButton(block: UInt8, keyType: MifareKeyType) {
        run("Find key") {
            if let k = try await self.findKey(block: block, keyType: keyType, keys: Self.defaultMifareKeys) {
                self.lastFoundKey = k
            } else {
                self.line("No dictionary key for block \(block) (key \(keyType == .keyA ? "A" : "B")).")
            }
        }
    }

    // MARK: - Parsing helpers

    private func u32be(_ d: [UInt8], _ o: Int) -> UInt32 {
        (UInt32(d[o]) << 24) | (UInt32(d[o+1]) << 16) | (UInt32(d[o+2]) << 8) | UInt32(d[o+3])
    }
    private func u64be(_ d: [UInt8], _ o: Int) -> UInt64 {
        var r: UInt64 = 0; for i in 0..<8 { r = (r << 8) | UInt64(d[o+i]) }; return r
    }

    // MARK: - Magic card UID / block 0 write

    struct RawOpts { var activate=false, wait=false, crc=false, autosel=false, keep=false, checkcrc=false }
    private func rawOptionsByte(_ o: RawOpts) -> UInt8 {
        var b: UInt8 = 0
        if o.activate { b |= 1 << 7 }; if o.wait { b |= 1 << 6 }; if o.crc { b |= 1 << 5 }
        if o.autosel { b |= 1 << 4 }; if o.keep { b |= 1 << 3 }; if o.checkcrc { b |= 1 << 2 }
        return b
    }
    /// HF14A_RAW: options(1) | timeout_ms(2 BE) | bitlen(2 BE) | data
    private func hf14aRaw(_ opts: RawOpts, data: [UInt8], bitlen: Int? = nil, timeoutMs: Int = 1000) async throws -> [UInt8] {
        let bits = bitlen ?? data.count * 8
        var payload: [UInt8] = [rawOptionsByte(opts),
            UInt8((timeoutMs >> 8) & 0xFF), UInt8(timeoutMs & 0xFF),
            UInt8((bits >> 8) & 0xFF), UInt8(bits & 0xFF)]
        payload.append(contentsOf: data)
        let resp = try await ble.send(.hf14aRaw, data: payload, timeout: Double(timeoutMs) / 1000 + 2)
        return resp.data
    }

    static func buildBlock0(uid: [UInt8]) -> [UInt8] {
        let bcc = uid[0] ^ uid[1] ^ uid[2] ^ uid[3]
        return uid + [bcc, 0x08, 0x04, 0x00] + [UInt8](repeating: 0, count: 8)
    }

    private func gen1aWriteBlock(_ block: UInt8, data16: [UInt8]) async throws -> Bool {
        let keep = RawOpts(activate: true, wait: true, keep: true)
        let crc  = RawOpts(activate: true, wait: true, crc: true, keep: true, checkcrc: true)
        var r = try await hf14aRaw(keep, data: [0x40], bitlen: 7)
        guard r.first == 0x0A else { line("Gen1A unlock 1 failed — not a Gen1a magic card?"); return false }
        r = try await hf14aRaw(keep, data: [0x43])
        guard r.first == 0x0A else { line("Gen1A unlock 2 failed."); return false }
        r = try await hf14aRaw(crc, data: [0xA0, block])
        guard r.first == 0x0A else { line("Gen1A write command not ACKed for block \(block)."); return false }
        r = try await hf14aRaw(crc, data: data16)
        let ok = r.first == 0x0A
        _ = try? await hf14aRaw(RawOpts(activate: true), data: [], timeoutMs: 100) // drop field
        return ok
    }

    /// Write a 16-byte block 0 to a magic card. gen1a uses the backdoor; gen2 uses a normal write.
    func writeUidButton(block0: [UInt8], gen1a: Bool, key: [UInt8], keyType: MifareKeyType) {
        run("Write UID") {
            guard block0.count == 16 else { self.line("Block 0 must be 16 bytes."); return }
            try await self.setReaderMode(true)
            if gen1a {
                _ = try await self.gen1aWriteBlock(0, data16: block0)
                self.line("Gen1A UID write done.")
            } else {
                guard key.count == 6 else { self.line("Gen2 needs a 6-byte key."); return }
                let ok = try await self.mfWriteBlock(0, data16: block0, key: key, keyType: keyType)
                self.line(ok ? "Gen2: wrote UID to block 0." : "Gen2 UID write failed.")
            }
        }
    }

    // MARK: - Detect / acquire commands

    private func detectPrng() async throws -> UInt8? {
        let r = try await ble.send(.mf1DetectPrng)
        guard r.hfOk, let b = r.data.first else { return nil }
        return b
    }
    private func detectNtDist(block: UInt8, type: MifareKeyType, key: [UInt8]) async throws -> (uid: UInt32, dist: UInt32)? {
        var data: [UInt8] = [type.rawValue, block]; data += key
        let r = try await ble.send(.mf1DetectNtDist, data: data, timeout: 20)
        guard r.hfOk, r.data.count >= 8 else { return nil }
        return (u32be(r.data, 0), u32be(r.data, 4))
    }
    private func nestedAcquire(knownBlock: UInt8, knownType: MifareKeyType, knownKey: [UInt8],
                               targetBlock: UInt8, targetType: MifareKeyType) async throws -> [(UInt32, UInt32, UInt8)]? {
        var data: [UInt8] = [knownType.rawValue, knownBlock]; data += knownKey; data += [targetType.rawValue, targetBlock]
        let r = try await ble.send(.mf1NestedAcquire, data: data, timeout: 20)
        guard r.hfOk else { return nil }
        var res: [(UInt32, UInt32, UInt8)] = []; var o = 0
        while o + 9 <= r.data.count { res.append((u32be(r.data, o), u32be(r.data, o+4), r.data[o+8])); o += 9 }
        return res
    }
    private func staticNestedAcquire(knownBlock: UInt8, knownType: MifareKeyType, knownKey: [UInt8],
                                     targetBlock: UInt8, targetType: MifareKeyType) async throws -> (uid: UInt32, pairs: [(UInt32, UInt32)])? {
        var data: [UInt8] = [knownType.rawValue, knownBlock]; data += knownKey; data += [targetType.rawValue, targetBlock]
        let r = try await ble.send(.mf1StaticNestedAcquire, data: data, timeout: 20)
        guard r.hfOk, r.data.count >= 4 else { return nil }
        let uid = u32be(r.data, 0); var pairs: [(UInt32, UInt32)] = []; var o = 4
        while o + 8 <= r.data.count { pairs.append((u32be(r.data, o), u32be(r.data, o+4))); o += 8 }
        return (uid, pairs)
    }
    private func darksideAcquire(block: UInt8, type: MifareKeyType, firstRecover: Bool, syncMax: UInt8)
        async throws -> (status: UInt8, uid: UInt32, nt1: UInt32, par: UInt64, ks1: UInt64, nr: UInt32, ar: UInt32)? {
        let data: [UInt8] = [type.rawValue, block, firstRecover ? 1 : 0, syncMax]
        let r = try await ble.send(.mf1DarksideAcquire, data: data, timeout: 60)
        guard r.data.count >= 33 else { return nil }
        let d = r.data
        return (d[0], u32be(d, 1), u32be(d, 5), u64be(d, 9), u64be(d, 17), u32be(d, 25), u32be(d, 29))
    }
    private func authKey(block: UInt8, type: MifareKeyType, key: [UInt8]) async throws -> Bool {
        var data: [UInt8] = [type.rawValue, block]; data += key
        let r = try await ble.send(.mf1AuthOneKeyBlock, data: data)
        return r.hfOk
    }

    // MARK: - Nested / static-nested recovery (native solver)

    func recoverNestedButton(knownBlock: UInt8, knownType: MifareKeyType, knownKey: [UInt8],
                             targetBlock: UInt8, targetType: MifareKeyType) {
        run("Recover key") {
            try await self.setReaderMode(true)
            guard let lvl = try await self.detectPrng() else { self.line("PRNG detect failed."); return }
            self.line("NT vulnerability: \(lvl == 0 ? "static" : lvl == 1 ? "weak (nested)" : lvl == 2 ? "hard (hardnested)" : "unknown (\(lvl))")")
            if lvl == 2 { self.line("Hardnested required — not supported in this build."); return }

            var candidates: [UInt64] = []
            if lvl == 0 {
                guard let acq = try await self.staticNestedAcquire(knownBlock: knownBlock, knownType: knownType, knownKey: knownKey,
                                                                   targetBlock: targetBlock, targetType: targetType), !acq.pairs.isEmpty else {
                    self.line("Static-nested acquire failed."); return
                }
                self.line("Acquired \(acq.pairs.count) static nonces (uid \(String(format: "%08X", acq.uid))).")
                candidates = KeyRecovery.staticNested(uid: acq.uid, type: targetType.rawValue,
                                                      nts: acq.pairs.map { $0.0 }, ntEncs: acq.pairs.map { $0.1 })
            } else {
                guard let nd = try await self.detectNtDist(block: knownBlock, type: knownType, key: knownKey) else {
                    self.line("NT-distance detect failed."); return
                }
                guard let triples = try await self.nestedAcquire(knownBlock: knownBlock, knownType: knownType, knownKey: knownKey,
                                                                 targetBlock: targetBlock, targetType: targetType), !triples.isEmpty else {
                    self.line("Nested acquire failed."); return
                }
                self.line("Acquired \(triples.count) nested nonces (uid \(String(format: "%08X", nd.uid)), dist \(nd.dist)).")
                candidates = KeyRecovery.nested(uid: nd.uid, dist: nd.dist,
                                                nts: triples.map { $0.0 }, ntEncs: triples.map { $0.1 }, pars: triples.map { $0.2 })
            }

            if candidates.isEmpty { self.line("No key recovered — acquisition is probabilistic, try again."); return }
            self.line("\(candidates.count) candidate(s); verifying on card…")
            for k in candidates {
                let kb = KeyRecovery.keyBytes(k)
                if try await self.authKey(block: targetBlock, type: targetType, key: kb) {
                    self.lastFoundKey = kb
                    self.line("✅ Recovered key \(targetType == .keyA ? "A" : "B") for block \(targetBlock): \(ChameleonFrame.hex(kb))")
                    return
                }
            }
            self.line("Candidates found but none verified — re-run acquire.")
        }
    }

    // MARK: - Darkside recovery (native solver)

    func recoverDarksideButton(block: UInt8, type: MifareKeyType) {
        run("Darkside") {
            try await self.setReaderMode(true)
            self.line("Darkside: acquiring (no known key needed)…")
            var nts: [UInt32] = [], ks: [UInt64] = [], par: [UInt64] = [], nrs: [UInt32] = [], ars: [UInt32] = []
            var uid: UInt32 = 0
            var firstRecover = true
            let maxRetry = 20
            for retry in 0 ..< maxRetry {
                guard let a = try await self.darksideAcquire(block: block, type: type, firstRecover: firstRecover, syncMax: 30) else {
                    self.line("Darkside acquire: short response."); return
                }
                firstRecover = false
                if a.status != 0 {
                    let names: [UInt8: String] = [1: "CANT_FIX_NT (unpredictable PRNG — needs hardnested)", 2: "LUCKY_AUTH_OK (default key?)", 3: "NO_NAK_SENT", 4: "TAG_CHANGED"]
                    self.line("Darkside stopped: \(names[a.status] ?? "status \(a.status)")"); return
                }
                uid = a.uid
                if a.par != 0 { nts.removeAll(); ks.removeAll(); par.removeAll(); nrs.removeAll(); ars.removeAll() } // NXP workaround
                nts.append(a.nt1); ks.append(a.ks1); par.append(a.par); nrs.append(a.nr); ars.append(a.ar)

                let candidates = KeyRecovery.darkside(uid: uid, nts: nts, ksLists: ks, parLists: par, nrs: nrs, ars: ars)
                if candidates.isEmpty { self.line("No key yet (\(nts.count) set\(nts.count > 1 ? "s" : "")), retrying (\(retry + 1))…"); continue }

                self.line("\(candidates.count) candidate(s); verifying on card…")
                for k in candidates {
                    let kb = KeyRecovery.keyBytes(k)
                    if try await self.authKey(block: block, type: type, key: kb) {
                        self.lastFoundKey = kb
                        self.line("✅ Darkside recovered key \(type == .keyA ? "A" : "B") for block \(block): \(ChameleonFrame.hex(kb))")
                        return
                    }
                }
                self.line("Candidates didn't verify, retrying (\(retry + 1))…")
            }
            self.line("Darkside: no key recovered after max retries.")
        }
    }

    // MARK: - Slots & emulation

    static let senseLF: UInt8 = 1
    static let senseHF: UInt8 = 2

    static func tagName(_ v: Int) -> String {
        switch v {
        case 0:    return "—"
        case 100:  return "EM410x"
        case 1000: return "MIFARE Mini"
        case 1001: return "MIFARE 1K"
        case 1003: return "MIFARE 4K"
        case 1100: return "NTAG213"
        case 1101: return "NTAG215"
        case 1102: return "NTAG216"
        default:   return v != 0 ? "type \(v)" : "—"
        }
    }

    private func loadSlotsInner() async throws {
        let act = try await ble.send(.getActiveSlot)
        let en = try await ble.send(.getEnabledSlots)
        let info = try await ble.send(.getSlotInfo)
        guard en.genericOk, info.genericOk else { line("Failed to read slots."); return }
        activeSlot = Int(act.data.first ?? 0)
        var rows: [SlotRow] = []
        for i in 0..<8 {
            let hfEn = en.data.count > i*2   && en.data[i*2]   != 0
            let lfEn = en.data.count > i*2+1 && en.data[i*2+1] != 0
            let hfType = info.data.count > i*4+1 ? (Int(info.data[i*4]) << 8 | Int(info.data[i*4+1])) : 0
            let lfType = info.data.count > i*4+3 ? (Int(info.data[i*4+2]) << 8 | Int(info.data[i*4+3])) : 0
            rows.append(SlotRow(id: i, hfEnabled: hfEn, lfEnabled: lfEn, hfType: hfType, lfType: lfType))
        }
        slots = rows
    }

    func loadSlots() { run("Slots") { try await self.loadSlotsInner() } }

    func setActiveSlotButton(_ n: Int) {
        run("Active slot") {
            let r = try await self.ble.send(.setActiveSlot, data: [UInt8(n)])
            if r.genericOk { self.line("Active slot → \(n + 1)"); try await self.loadSlotsInner() }
            else { self.line("Set active failed (\(r.statusEnum.label)).") }
        }
    }

    func setSlotEnableButton(slot: Int, sense: UInt8, enabled: Bool) {
        run("Slot enable") {
            let r = try await self.ble.send(.setSlotEnable, data: [UInt8(slot), sense, enabled ? 1 : 0])
            if r.genericOk {
                self.line("Slot \(slot + 1) \(sense == Self.senseHF ? "HF" : "LF") \(enabled ? "enabled" : "disabled")")
                try await self.loadSlotsInner()
            } else { self.line("Enable/disable failed (\(r.statusEnum.label)).") }
        }
    }

    func saveConfig() {
        run("Save") {
            let r = try await self.ble.send(.slotDataConfigSave, timeout: 5)
            self.line(r.genericOk ? "Slot config saved to flash." : "Save failed (\(r.statusEnum.label)).")
        }
    }

    func setMode(reader: Bool) {
        run("Mode") {
            _ = try await self.ble.send(.changeDeviceMode, data: [reader ? 1 : 0])
            self.line(reader ? "Reader mode." : "Emulate (tag) mode — Chameleon now acts as the active slot's card.")
        }
    }

    func emulateHF() {
        run("Emulate HF") {
            guard let t = self.lastHFTag else { self.line("Scan an HF tag first."); return }
            let slot = UInt8(self.activeSlot)
            _ = try await self.ble.send(.setSlotTagType, data: [slot, UInt8((1001 >> 8) & 0xFF), UInt8(1001 & 0xFF)])
            var p: [UInt8] = [UInt8(t.uid.count)]; p += t.uid; p += t.atqa; p.append(t.sak); p.append(UInt8(t.ats.count)); p += t.ats
            let r = try await self.ble.send(.hf14aSetAntiColl, data: p)
            guard r.genericOk else { self.line("Set anti-coll failed (\(r.statusEnum.label))."); return }
            _ = try await self.ble.send(.slotDataConfigSave)
            _ = try await self.ble.send(.changeDeviceMode, data: [0])
            self.line("Emulating UID \(ChameleonFrame.hexSpaced(t.uid)) on slot \(self.activeSlot + 1) (tag mode). Present it to a reader.")
            try await self.loadSlotsInner()
        }
    }

    func emulateLF() {
        run("Emulate LF") {
            guard let id = self.lastReadId else { self.line("Read an EM410x tag first."); return }
            let slot = UInt8(self.activeSlot)
            _ = try await self.ble.send(.setSlotTagType, data: [slot, UInt8((100 >> 8) & 0xFF), UInt8(100 & 0xFF)])
            let r = try await self.ble.send(.em410xSetEmuId, data: id)
            guard r.genericOk else { self.line("Set EM410x emu id failed (\(r.statusEnum.label))."); return }
            _ = try await self.ble.send(.slotDataConfigSave)
            _ = try await self.ble.send(.changeDeviceMode, data: [0])
            self.line("Emulating EM410x \(ChameleonFrame.hexSpaced(id)) on slot \(self.activeSlot + 1) (tag mode).")
            try await self.loadSlotsInner()
        }
    }
}

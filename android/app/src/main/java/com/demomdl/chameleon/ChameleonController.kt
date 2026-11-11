package com.demomdl.chameleon

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class HFTag(val uid: ByteArray, val atqa: ByteArray, val sak: Int, val ats: ByteArray) {
    val kindName: String
    val clonable: Boolean
    val note: String
    init {
        when {
            sak and 0x20 != 0 -> { kindName = "ISO 14443-4 (DESFire / secure)"; clonable = false; note = "Encrypted / mutual-auth — not clonable by any app." }
            sak == 0x00 -> { kindName = "NTAG / MIFARE Ultralight"; clonable = true; note = "Writable directly (no keys needed)." }
            sak == 0x08 || sak == 0x09 -> { kindName = "MIFARE Classic 1K"; clonable = true; note = "Needs sector keys to read; a magic card to write UID." }
            sak == 0x18 -> { kindName = "MIFARE Classic 4K"; clonable = true; note = "Needs sector keys to read; a magic card to write UID." }
            else -> { kindName = "Unknown HF tag"; clonable = false; note = "Couldn't classify from SAK/ATQA." }
        }
    }
}

data class SlotRow(val index: Int, val hfEnabled: Boolean, val lfEnabled: Boolean, val hfType: Int, val lfType: Int)

class ChameleonController(app: Application) : AndroidViewModel(app) {

    val ble = ChameleonBle(app)

    private val _log = MutableStateFlow<List<String>>(emptyList())
    val log: StateFlow<List<String>> = _log.asStateFlow()
    private val _connected = MutableStateFlow(false)
    val connected: StateFlow<Boolean> = _connected.asStateFlow()
    private val _busy = MutableStateFlow(false)
    val busy: StateFlow<Boolean> = _busy.asStateFlow()
    private val _deviceInfo = MutableStateFlow("")
    val deviceInfo: StateFlow<String> = _deviceInfo.asStateFlow()
    private val _lastId = MutableStateFlow<String?>(null)   // last EM410x id (hex)
    val lastId: StateFlow<String?> = _lastId.asStateFlow()
    private val _lastHF = MutableStateFlow<HFTag?>(null)
    val lastHF: StateFlow<HFTag?> = _lastHF.asStateFlow()
    private val _foundKey = MutableStateFlow<String?>(null)  // last recovered key (hex)
    val foundKey: StateFlow<String?> = _foundKey.asStateFlow()
    private val _slots = MutableStateFlow<List<SlotRow>>(emptyList())
    val slots: StateFlow<List<SlotRow>> = _slots.asStateFlow()
    private val _activeSlot = MutableStateFlow(0)
    val activeSlot: StateFlow<Int> = _activeSlot.asStateFlow()

    private var lastIdBytes: ByteArray? = null

    companion object {
        val T55_NEW_KEY = byteArrayOf(0x20, 0x20, 0x66, 0x66)
        val T55_OLD_KEYS = arrayOf(
            byteArrayOf(0x51, 0x24, 0x36, 0x48),
            byteArrayOf(0x19.toByte(), 0x92.toByte(), 0x04, 0x27)
        )
        val DICT: Array<ByteArray> = arrayOf(
            byteArrayOf(-1, -1, -1, -1, -1, -1),                 // FFFFFFFFFFFF
            byteArrayOf(0, 0, 0, 0, 0, 0),
            byteArrayOf(0xA0.toByte(), 0xA1.toByte(), 0xA2.toByte(), 0xA3.toByte(), 0xA4.toByte(), 0xA5.toByte()),
            byteArrayOf(0xD3.toByte(), 0xF7.toByte(), 0xD3.toByte(), 0xF7.toByte(), 0xD3.toByte(), 0xF7.toByte()),
            byteArrayOf(0xB0.toByte(), 0xB1.toByte(), 0xB2.toByte(), 0xB3.toByte(), 0xB4.toByte(), 0xB5.toByte()),
            byteArrayOf(0x4D, 0x3A, 0x99.toByte(), 0xC3.toByte(), 0x51, 0xDD.toByte()),
            byteArrayOf(0x1A, 0x98.toByte(), 0x2C, 0x7E, 0x45, 0x9A.toByte()),
            byteArrayOf(0xAA.toByte(), 0xBB.toByte(), 0xCC.toByte(), 0xDD.toByte(), 0xEE.toByte(), 0xFF.toByte()),
            byteArrayOf(0x71, 0x4C, 0x5C, 0x88.toByte(), 0x6E, 0x97.toByte()),
            byteArrayOf(0x58, 0x7E, 0xE5.toByte(), 0xF9.toByte(), 0x35, 0x0F),
            byteArrayOf(0xA0.toByte(), 0x47, 0x8C.toByte(), 0xC3.toByte(), 0x90.toByte(), 0x91.toByte()),
            byteArrayOf(0x53, 0x3C, 0xB6.toByte(), 0xC7.toByte(), 0x23, 0xF6.toByte()),
            byteArrayOf(0x8F.toByte(), 0xD0.toByte(), 0xA4.toByte(), 0xF2.toByte(), 0x56, 0xE9.toByte())
        )

        fun buildBlock0(uid: ByteArray): ByteArray {
            val bcc = (uid[0].toInt() xor uid[1].toInt() xor uid[2].toInt() xor uid[3].toInt()).toByte()
            return uid + byteArrayOf(bcc, 0x08, 0x04, 0x00) + ByteArray(8)
        }
    }

    init {
        ble.onLog = { line -> appendLog(line) }
        ble.onConnectionChange = { v -> _connected.value = v }
    }

    private fun appendLog(s: String) {
        val cur = _log.value
        val next = if (cur.size > 600) cur.drop(cur.size - 600) + s else cur + s
        _log.value = next
    }
    private fun log(s: String) = appendLog(s)

    private fun run(title: String, body: suspend () -> Unit) {
        if (_busy.value) { log("Busy — wait for the current step."); return }
        _busy.value = true
        viewModelScope.launch {
            try { body() } catch (e: Exception) { log("$title error: ${e.message}") }
            _busy.value = false
        }
    }

    // Parsing helpers
    private fun u32(d: ByteArray, o: Int): Int =
        ((d[o].toInt() and 0xFF) shl 24) or ((d[o + 1].toInt() and 0xFF) shl 16) or
        ((d[o + 2].toInt() and 0xFF) shl 8) or (d[o + 3].toInt() and 0xFF)
    private fun u64(d: ByteArray, o: Int): Long {
        var r = 0L; for (i in 0 until 8) r = (r shl 8) or (d[o + i].toLong() and 0xFF); return r
    }

    // MARK: Connection + info
    fun connect() = run("Connect") {
        ble.connect()
        readDeviceInfo()
    }
    fun disconnect() = ble.disconnect()

    private suspend fun readDeviceInfo() {
        val parts = ArrayList<String>()
        runCatching { val v = ble.send(Cmd.GET_APP_VERSION); if (v.data.size >= 2) parts.add("fw ${v.data[0].toInt() and 0xFF}.${v.data[1].toInt() and 0xFF}") }
        runCatching { val c = ble.send(Cmd.GET_DEVICE_CHIP_ID); if (c.data.isNotEmpty()) parts.add("chip ${c.data.hex()}") }
        runCatching { val b = ble.send(Cmd.GET_BATTERY_INFO); if (b.data.size >= 3) { val mv = ((b.data[0].toInt() and 0xFF) shl 8) or (b.data[1].toInt() and 0xFF); parts.add("battery ${b.data[2].toInt() and 0xFF}% ($mv mV)") } }
        _deviceInfo.value = parts.joinToString("  ·  ")
        if (parts.isNotEmpty()) log("Device: ${_deviceInfo.value}")
    }

    private suspend fun setReaderMode(reader: Boolean) {
        ble.send(Cmd.CHANGE_DEVICE_MODE, byteArrayOf((if (reader) 1 else 0).toByte()))
    }

    // MARK: LF EM410x
    private suspend fun readEM410xInner(): ByteArray? {
        setReaderMode(true)
        val r = ble.send(Cmd.EM410X_SCAN)
        if (!r.lfOk || r.data.size < 7) { log("No EM410x tag found (${Status.label(r.status)})."); return null }
        val id = r.data.copyOfRange(2, 7)
        lastIdBytes = id; _lastId.value = id.hexSpaced()
        log("EM410x ID: ${id.hexSpaced()}")
        return id
    }
    fun readEM410x() = run("Read") { readEM410xInner() }

    private suspend fun writeEM410x(id: ByteArray): Boolean {
        if (id.size != 5) { log("ID must be 5 bytes."); return false }
        setReaderMode(true)
        val payload = id + T55_NEW_KEY + T55_OLD_KEYS[0] + T55_OLD_KEYS[1]
        val r = ble.send(Cmd.EM410X_WRITE_TO_T55XX, payload, 8000)
        return if (r.lfOk) { log("Write OK (EM4100 preset written to T5577)."); true }
        else { log("Write failed (${Status.label(r.status)})."); false }
    }
    fun writeAndVerify() = run("Clone") {
        val id = lastIdBytes
        if (id == null) { log("Read the source tag first."); return@run }
        if (!writeEM410x(id)) return@run
        log("Verifying — scanning the card back…")
        val read = readEM410xInner()
        if (read == null) { log("Verify: FAIL (no tag)"); return@run }
        if (read.contentEquals(id)) log("Verify: PASS ✅") else log("Verify: FAIL ❌ (read ${read.hexSpaced()})")
    }

    // MARK: HF scan
    fun hfScan() = run("HF scan") {
        setReaderMode(true)
        val r = ble.send(Cmd.HF14A_SCAN)
        if (!r.hfOk || r.data.isEmpty()) { log("No HF tag found (${Status.label(r.status)})."); return@run }
        val d = r.data; var o = 0
        val uidlen = d[o].toInt() and 0xFF; o += 1
        if (d.size < o + uidlen + 4) { log("Malformed HF response."); return@run }
        val uid = d.copyOfRange(o, o + uidlen); o += uidlen
        val atqa = d.copyOfRange(o, o + 2); o += 2
        val sak = d[o].toInt() and 0xFF; o += 1
        val atslen = d[o].toInt() and 0xFF; o += 1
        val ats = if (atslen > 0 && d.size >= o + atslen) d.copyOfRange(o, o + atslen) else ByteArray(0)
        val tag = HFTag(uid, atqa, sak, ats); _lastHF.value = tag
        log("HF UID ${uid.hexSpaced()}  SAK %02X  ATQA ${atqa.hexSpaced()}".format(sak))
        log("Type: ${tag.kindName} — ${if (tag.clonable) "clonable" else "NOT clonable"}")
        log(tag.note)
    }

    // MARK: MIFARE block + find key
    fun mfRead(block: Int, key: ByteArray, type: KeyType) = run("Read block") {
        if (key.size != 6) { log("Key must be 6 bytes."); return@run }
        setReaderMode(true)
        val r = ble.send(Cmd.MF1_READ_ONE_BLOCK, byteArrayOf(type.raw.toByte(), block.toByte()) + key)
        if (r.hfOk && r.data.size == 16) log("Block $block: ${r.data.hexSpaced()}")
        else log("Read block $block failed (${Status.label(r.status)}).")
    }
    fun mfWrite(block: Int, data16: ByteArray, key: ByteArray, type: KeyType) = run("Write block") {
        if (key.size != 6) { log("Key must be 6 bytes."); return@run }
        if (data16.size != 16) { log("Block data must be 16 bytes."); return@run }
        setReaderMode(true)
        val r = ble.send(Cmd.MF1_WRITE_ONE_BLOCK, byteArrayOf(type.raw.toByte(), block.toByte()) + key + data16)
        if (r.hfOk) log("Wrote block $block.") else log("Write block $block failed (${Status.label(r.status)}).")
    }
    fun findKey(block: Int, type: KeyType) = run("Find key") {
        setReaderMode(true)
        val keys = DICT
        var payload = byteArrayOf(block.toByte(), type.raw.toByte(), keys.size.toByte())
        for (k in keys) payload += k
        val r = ble.send(Cmd.MF1_CHECK_KEYS_ON_BLOCK, payload, 15000)
        if (r.data.size >= 7 && r.data[0].toInt() != 0) {
            val key = r.data.copyOfRange(1, 7)
            _foundKey.value = key.hex()
            log("Found key ${type.name} for block $block: ${key.hex()}")
        } else log("No dictionary key for block $block (key ${type.name}).")
    }

    // MARK: Magic UID
    private fun rawOptions(activate: Boolean, wait: Boolean, crc: Boolean, keep: Boolean, checkcrc: Boolean): Byte {
        var b = 0
        if (activate) b = b or (1 shl 7); if (wait) b = b or (1 shl 6); if (crc) b = b or (1 shl 5)
        if (keep) b = b or (1 shl 3); if (checkcrc) b = b or (1 shl 2)
        return b.toByte()
    }
    private suspend fun hf14aRaw(opts: Byte, data: ByteArray, bitlen: Int? = null, timeoutMs: Int = 1000): ByteArray {
        val bits = bitlen ?: data.size * 8
        val payload = byteArrayOf(opts,
            ((timeoutMs shr 8) and 0xFF).toByte(), (timeoutMs and 0xFF).toByte(),
            ((bits shr 8) and 0xFF).toByte(), (bits and 0xFF).toByte()) + data
        return ble.send(Cmd.HF14A_RAW, payload, (timeoutMs + 2000).toLong()).data
    }
    private suspend fun gen1aWriteBlock(block: Int, data16: ByteArray): Boolean {
        val keep = rawOptions(true, true, false, true, false)
        val crc = rawOptions(true, true, true, true, true)
        var r = hf14aRaw(keep, byteArrayOf(0x40), 7)
        if (r.isEmpty() || r[0].toInt() and 0xFF != 0x0A) { log("Gen1A unlock 1 failed — not a Gen1a magic card?"); return false }
        r = hf14aRaw(keep, byteArrayOf(0x43))
        if (r.isEmpty() || r[0].toInt() and 0xFF != 0x0A) { log("Gen1A unlock 2 failed."); return false }
        r = hf14aRaw(crc, byteArrayOf(0xA0.toByte(), block.toByte()))
        if (r.isEmpty() || r[0].toInt() and 0xFF != 0x0A) { log("Gen1A write command not ACKed."); return false }
        r = hf14aRaw(crc, data16)
        val ok = r.isNotEmpty() && (r[0].toInt() and 0xFF == 0x0A)
        runCatching { hf14aRaw(rawOptions(true, false, false, false, false), ByteArray(0), null, 100) }
        return ok
    }
    fun writeUid(block0: ByteArray, gen1a: Boolean, key: ByteArray, type: KeyType) = run("Write UID") {
        if (block0.size != 16) { log("Block 0 must be 16 bytes — build it first."); return@run }
        setReaderMode(true)
        if (gen1a) {
            val ok = gen1aWriteBlock(0, block0)
            log(if (ok) "Gen1A UID write done." else "Gen1A UID write failed.")
        } else {
            if (key.size != 6) { log("Gen2 needs a 6-byte key."); return@run }
            val r = ble.send(Cmd.MF1_WRITE_ONE_BLOCK, byteArrayOf(type.raw.toByte(), 0) + key + block0)
            log(if (r.hfOk) "Gen2: wrote UID to block 0." else "Gen2 UID write failed (${Status.label(r.status)}).")
        }
    }

    // MARK: Detect / acquire
    private suspend fun detectPrng(): Int? {
        val r = ble.send(Cmd.MF1_DETECT_PRNG)
        return if (r.hfOk && r.data.isNotEmpty()) r.data[0].toInt() and 0xFF else null
    }
    private suspend fun authKey(block: Int, type: KeyType, key: ByteArray): Boolean {
        val r = ble.send(Cmd.MF1_AUTH_ONE_KEY_BLOCK, byteArrayOf(type.raw.toByte(), block.toByte()) + key)
        return r.hfOk
    }

    // MARK: Nested recovery (native solver)
    fun recoverNested(knownBlock: Int, knownType: KeyType, knownKey: ByteArray, targetBlock: Int, targetType: KeyType) = run("Recover key") {
        if (knownKey.size != 6) { log("Known key must be 6 bytes."); return@run }
        setReaderMode(true)
        val lvl = detectPrng()
        if (lvl == null) { log("PRNG detect failed."); return@run }
        log("NT vulnerability: " + when (lvl) { 0 -> "static"; 1 -> "weak (nested)"; 2 -> "hard (hardnested)"; else -> "unknown ($lvl)" })
        if (lvl == 2) { log("Hardnested required — not supported in this build."); return@run }

        var candidates: LongArray = LongArray(0)
        val acqData = byteArrayOf(knownType.raw.toByte(), knownBlock.toByte()) + knownKey + byteArrayOf(targetType.raw.toByte(), targetBlock.toByte())
        if (lvl == 0) {
            val r = ble.send(Cmd.MF1_STATIC_NESTED_ACQUIRE, acqData, 20000)
            if (!r.hfOk || r.data.size < 12) { log("Static-nested acquire failed (${Status.label(r.status)})."); return@run }
            val uid = u32(r.data, 0)
            val nts = ArrayList<Int>(); val encs = ArrayList<Int>()
            var o = 4; while (o + 8 <= r.data.size) { nts.add(u32(r.data, o)); encs.add(u32(r.data, o + 4)); o += 8 }
            log("Acquired ${nts.size} static nonces (uid %08X).".format(uid))
            val ntsA = nts.toIntArray(); val encsA = encs.toIntArray()
            candidates = withContext(Dispatchers.Default) { KeyRecovery.staticNested(uid, targetType.raw, ntsA, encsA) }
        } else {
            val d = ble.send(Cmd.MF1_DETECT_NT_DIST, byteArrayOf(knownType.raw.toByte(), knownBlock.toByte()) + knownKey, 20000)
            if (!d.hfOk || d.data.size < 8) { log("NT-distance detect failed (${Status.label(d.status)})."); return@run }
            val uid = u32(d.data, 0); val dist = u32(d.data, 4)
            val r = ble.send(Cmd.MF1_NESTED_ACQUIRE, acqData, 20000)
            if (!r.hfOk || r.data.size < 9) { log("Nested acquire failed (${Status.label(r.status)})."); return@run }
            val nts = ArrayList<Int>(); val encs = ArrayList<Int>(); val pars = ArrayList<Byte>()
            var o = 0; while (o + 9 <= r.data.size) { nts.add(u32(r.data, o)); encs.add(u32(r.data, o + 4)); pars.add(r.data[o + 8]); o += 9 }
            log("Acquired ${nts.size} nested nonces (uid %08X, dist $dist).".format(uid))
            val ntsA = nts.toIntArray(); val encsA = encs.toIntArray(); val parsA = pars.toByteArray()
            candidates = withContext(Dispatchers.Default) { KeyRecovery.nested(uid, dist, ntsA, encsA, parsA) }
        }

        if (candidates.isEmpty()) { log("No key recovered — acquisition is probabilistic, try again."); return@run }
        log("${candidates.size} candidate(s); verifying on card…")
        for (k in candidates) {
            val kb = KeyRecovery.keyBytes(k)
            if (authKey(targetBlock, targetType, kb)) {
                _foundKey.value = kb.hex()
                log("✅ Recovered key ${targetType.name} for block $targetBlock: ${kb.hex()}")
                return@run
            }
        }
        log("Candidates found but none verified — re-run acquire.")
    }

    // MARK: Darkside recovery (native solver)
    fun recoverDarkside(block: Int, type: KeyType) = run("Darkside") {
        setReaderMode(true)
        log("Darkside: acquiring (no known key needed)…")
        val nts = ArrayList<Int>(); val ks = ArrayList<Long>(); val par = ArrayList<Long>()
        val nrs = ArrayList<Int>(); val ars = ArrayList<Int>()
        var uid = 0; var firstRecover = true
        val statusNames = mapOf(1 to "CANT_FIX_NT (unpredictable PRNG — needs hardnested)", 2 to "LUCKY_AUTH_OK (default key?)", 3 to "NO_NAK_SENT", 4 to "TAG_CHANGED")
        for (retry in 0 until 20) {
            val r = ble.send(Cmd.MF1_DARKSIDE_ACQUIRE, byteArrayOf(type.raw.toByte(), block.toByte(), (if (firstRecover) 1 else 0).toByte(), 30), 60000)
            firstRecover = false
            if (r.data.size < 33) { log("Darkside acquire: short response."); return@run }
            val st = r.data[0].toInt() and 0xFF
            if (st != 0) { log("Darkside stopped: ${statusNames[st] ?: "status $st"}"); return@run }
            uid = u32(r.data, 1)
            val nt1 = u32(r.data, 5); val parV = u64(r.data, 9); val ks1 = u64(r.data, 17); val nr = u32(r.data, 25); val ar = u32(r.data, 29)
            if (parV != 0L) { nts.clear(); ks.clear(); par.clear(); nrs.clear(); ars.clear() }
            nts.add(nt1); ks.add(ks1); par.add(parV); nrs.add(nr); ars.add(ar)

            val uidC = uid
            val ntsA = nts.toIntArray(); val ksA = ks.toLongArray(); val parA = par.toLongArray(); val nrsA = nrs.toIntArray(); val arsA = ars.toIntArray()
            val candidates = withContext(Dispatchers.Default) { KeyRecovery.darkside(uidC, ntsA, ksA, parA, nrsA, arsA) }
            if (candidates.isEmpty()) { log("No key yet (${nts.size} set(s)), retrying (${retry + 1})…"); continue }
            log("${candidates.size} candidate(s); verifying on card…")
            for (k in candidates) {
                val kb = KeyRecovery.keyBytes(k)
                if (authKey(block, type, kb)) {
                    _foundKey.value = kb.hex()
                    log("✅ Darkside recovered key ${type.name} for block $block: ${kb.hex()}")
                    return@run
                }
            }
            log("Candidates didn't verify, retrying (${retry + 1})…")
        }
        log("Darkside: no key recovered after max retries.")
    }

    // Slots & emulation
    private suspend fun loadSlotsInner() {
        val act = ble.send(Cmd.GET_ACTIVE_SLOT)
        val en = ble.send(Cmd.GET_ENABLED_SLOTS)
        val info = ble.send(Cmd.GET_SLOT_INFO)
        if (!en.genericOk || !info.genericOk) { log("Failed to read slots."); return }
        _activeSlot.value = if (act.data.isNotEmpty()) act.data[0].toInt() and 0xFF else 0
        val rows = ArrayList<SlotRow>()
        for (i in 0 until 8) {
            val hfEn = en.data.size > i * 2 && en.data[i * 2].toInt() != 0
            val lfEn = en.data.size > i * 2 + 1 && en.data[i * 2 + 1].toInt() != 0
            val hfType = if (info.data.size > i * 4 + 1) ((info.data[i * 4].toInt() and 0xFF) shl 8) or (info.data[i * 4 + 1].toInt() and 0xFF) else 0
            val lfType = if (info.data.size > i * 4 + 3) ((info.data[i * 4 + 2].toInt() and 0xFF) shl 8) or (info.data[i * 4 + 3].toInt() and 0xFF) else 0
            rows.add(SlotRow(i, hfEn, lfEn, hfType, lfType))
        }
        _slots.value = rows
    }
    fun loadSlots() = run("Slots") { loadSlotsInner() }

    fun setActiveSlot(n: Int) = run("Active slot") {
        val r = ble.send(Cmd.SET_ACTIVE_SLOT, byteArrayOf(n.toByte()))
        if (r.genericOk) { log("Active slot → ${n + 1}"); loadSlotsInner() } else log("Set active failed (${Status.label(r.status)}).")
    }

    fun setSlotEnable(slot: Int, sense: Int, enabled: Boolean) = run("Slot enable") {
        val r = ble.send(Cmd.SET_SLOT_ENABLE, byteArrayOf(slot.toByte(), sense.toByte(), (if (enabled) 1 else 0).toByte()))
        if (r.genericOk) { log("Slot ${slot + 1} ${if (sense == SENSE_HF) "HF" else "LF"} ${if (enabled) "enabled" else "disabled"}"); loadSlotsInner() }
        else log("Enable/disable failed (${Status.label(r.status)}).")
    }

    fun saveConfig() = run("Save") {
        val r = ble.send(Cmd.SLOT_DATA_CONFIG_SAVE, timeoutMs = 5000L)
        log(if (r.genericOk) "Slot config saved to flash." else "Save failed (${Status.label(r.status)}).")
    }

    fun setMode(reader: Boolean) = run("Mode") {
        ble.send(Cmd.CHANGE_DEVICE_MODE, byteArrayOf((if (reader) 1 else 0).toByte()))
        log(if (reader) "Reader mode." else "Emulate (tag) mode — Chameleon now acts as the active slot's card.")
    }

    private suspend fun setupSlotForEmulation(slot: Int, tagType: Int, sense: Int) {
        val hi = ((tagType shr 8) and 0xFF).toByte(); val lo = (tagType and 0xFF).toByte()
        ble.send(Cmd.SET_ACTIVE_SLOT, byteArrayOf(slot.toByte()))
        ble.send(Cmd.SET_SLOT_TAG_TYPE, byteArrayOf(slot.toByte(), hi, lo))
        ble.send(Cmd.SET_SLOT_DATA_DEFAULT, byteArrayOf(slot.toByte(), hi, lo))
        ble.send(Cmd.SET_SLOT_ENABLE, byteArrayOf(slot.toByte(), sense.toByte(), 1))
    }

    private suspend fun storeHFInner(): Boolean {
        val t = _lastHF.value
        if (t == null) { log("Scan an HF tag first."); return false }
        val slot = _activeSlot.value
        setupSlotForEmulation(slot, 1001, SENSE_HF) // MIFARE 1K
        val p = ArrayList<Byte>()
        p.add(t.uid.size.toByte()); p.addAll(t.uid.toList()); p.addAll(t.atqa.toList()); p.add(t.sak.toByte()); p.add(t.ats.size.toByte()); p.addAll(t.ats.toList())
        val r = ble.send(Cmd.HF14A_SET_ANTI_COLL_DATA, p.toByteArray())
        if (!r.genericOk) { log("Set anti-coll failed (${Status.label(r.status)})."); return false }
        ble.send(Cmd.SLOT_DATA_CONFIG_SAVE)
        loadSlotsInner()
        log("Saved HF UID ${t.uid.hexSpaced()} to slot ${slot + 1}.")
        return true
    }
    private suspend fun storeLFInner(): Boolean {
        val id = lastIdBytes
        if (id == null) { log("Read an EM410x tag first."); return false }
        val slot = _activeSlot.value
        setupSlotForEmulation(slot, 100, SENSE_LF) // EM410X
        val r = ble.send(Cmd.EM410X_SET_EMU_ID, id)
        if (!r.genericOk) { log("Set EM410x emu id failed (${Status.label(r.status)})."); return false }
        ble.send(Cmd.SLOT_DATA_CONFIG_SAVE)
        val g = ble.send(Cmd.EM410X_GET_EMU_ID)
        if (g.genericOk && g.data.size >= 5) log("Slot ${slot + 1} stores EM410x ${g.data.copyOfRange(0, 5).hexSpaced()} (readback).")
        loadSlotsInner()
        return true
    }
    fun storeHF() = run("Save HF to slot") { storeHFInner() }
    fun storeLF() = run("Save LF to slot") { storeLFInner() }

    fun emulateHF() = run("Emulate HF") {
        if (storeHFInner()) {
            ble.send(Cmd.CHANGE_DEVICE_MODE, byteArrayOf(0))
            log("Emulating on slot ${_activeSlot.value + 1} (tag mode). Present the HF antenna to a reader.")
        }
    }
    fun emulateLF() = run("Emulate LF") {
        if (storeLFInner()) {
            ble.send(Cmd.CHANGE_DEVICE_MODE, byteArrayOf(0))
            log("Emulating on slot ${_activeSlot.value + 1} (tag mode). Present the LF antenna to a reader.")
        }
    }
    fun setAnimation(full: Boolean) = run("LED mode") {
        ble.send(Cmd.SET_ANIMATION_MODE, byteArrayOf((if (full) 0 else 2).toByte()))
        ble.send(Cmd.SAVE_SETTINGS)
        log(if (full) "LED animation set to Full (saved). The LED now flashes on field detect." else "LED animation set to None (saved).")
    }
}

const val SENSE_LF = 1
const val SENSE_HF = 2
fun slotTagName(v: Int): String = when (v) {
    0 -> "—"; 100 -> "EM410x"; 1000 -> "MIFARE Mini"; 1001 -> "MIFARE 1K"; 1003 -> "MIFARE 4K"
    1100 -> "NTAG213"; 1101 -> "NTAG215"; 1102 -> "NTAG216"
    else -> if (v != 0) "type $v" else "—"
}

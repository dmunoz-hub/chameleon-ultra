package com.demomdl.chameleon

// Chameleon Ultra wire protocol. Frame:
//   SOF(0x11) | LRC1(0xEF) | CMD(2) | STATUS(2) | LEN(2) | LRC2 | DATA | LRC3  (big-endian)
// Command IDs/payloads ported from RfidResearchGroup/ChameleonUltra chameleon_cmd.py.

object Cmd {
    const val GET_APP_VERSION = 1000
    const val CHANGE_DEVICE_MODE = 1001
    const val SET_ACTIVE_SLOT = 1003
    const val SET_SLOT_TAG_TYPE = 1004
    const val SET_SLOT_DATA_DEFAULT = 1005
    const val SET_SLOT_ENABLE = 1006
    const val SLOT_DATA_CONFIG_SAVE = 1009
    const val GET_DEVICE_CHIP_ID = 1011
    const val SAVE_SETTINGS = 1013
    const val SET_ANIMATION_MODE = 1015
    const val GET_ACTIVE_SLOT = 1018
    const val GET_SLOT_INFO = 1019
    const val GET_ENABLED_SLOTS = 1023
    const val GET_BATTERY_INFO = 1025
    const val HF14A_SET_ANTI_COLL_DATA = 4001
    const val EM410X_SET_EMU_ID = 5000
    const val EM410X_GET_EMU_ID = 5001
    const val HF14A_SCAN = 2000
    const val MF1_DETECT_PRNG = 2002
    const val MF1_STATIC_NESTED_ACQUIRE = 2003
    const val MF1_DARKSIDE_ACQUIRE = 2004
    const val MF1_DETECT_NT_DIST = 2005
    const val MF1_NESTED_ACQUIRE = 2006
    const val MF1_AUTH_ONE_KEY_BLOCK = 2007
    const val MF1_READ_ONE_BLOCK = 2008
    const val MF1_WRITE_ONE_BLOCK = 2009
    const val HF14A_RAW = 2010
    const val MF1_CHECK_KEYS_ON_BLOCK = 2015
    const val EM410X_SCAN = 3000
    const val EM410X_WRITE_TO_T55XX = 3001
}

object Status {
    const val HF_TAG_OK = 0x00
    const val LF_TAG_OK = 0x40
    const val SUCCESS = 0x68
    fun label(s: Int) = when (s) {
        0x00 -> "HF tag OK"; 0x01 -> "no HF tag"; 0x06 -> "MIFARE auth failed"
        0x40 -> "LF tag OK"; 0x41 -> "no LF tag"; 0x66 -> "wrong device mode"
        0x67 -> "invalid command"; 0x68 -> "success"; 0x69 -> "not implemented"
        else -> "status 0x%02X".format(s)
    }
}

enum class KeyType(val raw: Int) { A(0x60), B(0x61) }

data class Response(val cmd: Int, val status: Int, val data: ByteArray) {
    val hfOk get() = status == Status.HF_TAG_OK
    val lfOk get() = status == Status.LF_TAG_OK
    val genericOk get() = status == Status.SUCCESS
}

fun ByteArray.hex(): String = joinToString("") { "%02X".format(it.toInt() and 0xFF) }
fun ByteArray.hexSpaced(): String = joinToString(" ") { "%02X".format(it.toInt() and 0xFF) }

fun parseHex(s: String): ByteArray {
    val h = s.filter { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' }
    val out = ArrayList<Byte>()
    var i = 0
    while (i + 1 < h.length + 1 && i + 2 <= h.length) {
        out.add(h.substring(i, i + 2).toInt(16).toByte()); i += 2
    }
    return out.toByteArray()
}

object Proto {
    private fun lrc(bytes: ByteArray, from: Int, len: Int): Byte {
        var s = 0
        for (i in from until from + len) s = (s + (bytes[i].toInt() and 0xFF)) and 0xFF
        return ((0x100 - s) and 0xFF).toByte()
    }

    fun build(cmd: Int, data: ByteArray = ByteArray(0)): ByteArray {
        val len = data.size
        val head = byteArrayOf(
            ((cmd shr 8) and 0xFF).toByte(), (cmd and 0xFF).toByte(),
            0, 0,
            ((len shr 8) and 0xFF).toByte(), (len and 0xFF).toByte()
        )
        val out = ByteArray(2 + 6 + 1 + len + 1)
        out[0] = 0x11
        out[1] = 0xEF.toByte()
        System.arraycopy(head, 0, out, 2, 6)
        out[8] = lrc(head, 0, 6)
        System.arraycopy(data, 0, out, 9, len)
        out[9 + len] = lrc(data, 0, len)
        return out
    }
}

/** Accumulates notification bytes and extracts complete frames; resyncs on bad SOF/LRC. */
class FrameBuffer {
    private val buf = ArrayList<Int>() // store as unsigned ints 0..255

    fun append(bytes: ByteArray) { for (b in bytes) buf.add(b.toInt() and 0xFF) }
    fun reset() { buf.clear() }

    private fun lrc(from: Int, len: Int): Int {
        var s = 0; for (i in from until from + len) s = (s + buf[i]) and 0xFF
        return (0x100 - s) and 0xFF
    }

    fun next(): Response? {
        while (true) {
            val start = buf.indexOf(0x11)
            if (start < 0) { buf.clear(); return null }
            if (start > 0) repeat(start) { buf.removeAt(0) }
            if (buf.size < 9) return null
            if (buf[1] != 0xEF) { buf.removeAt(0); continue }
            val cmd = (buf[2] shl 8) or buf[3]
            val status = (buf[4] shl 8) or buf[5]
            val len = (buf[6] shl 8) or buf[7]
            if (lrc(2, 6) != buf[8]) { buf.removeAt(0); continue }
            val total = 9 + len + 1
            if (buf.size < total) return null
            val data = ByteArray(len) { buf[9 + it].toByte() }
            if (lrc(9, len) != buf[9 + len]) { buf.removeAt(0); continue }
            repeat(total) { buf.removeAt(0) }
            return Response(cmd, status, data)
        }
    }
}

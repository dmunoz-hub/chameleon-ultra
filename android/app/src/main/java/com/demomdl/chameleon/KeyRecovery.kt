package com.demomdl.chameleon

/** Native Crypto1 solvers (the firmware's C code) via JNI -> libsolver.so. */
object KeyRecovery {
    init { System.loadLibrary("solver") }

    external fun nested(uid: Int, dist: Int, nt: IntArray, ntEnc: IntArray, par: ByteArray): LongArray
    external fun staticNested(uid: Int, type: Int, nt: IntArray, ntEnc: IntArray): LongArray
    external fun darkside(uid: Int, nt: IntArray, ksList: LongArray, parList: LongArray, nr: IntArray, ar: IntArray): LongArray

    /** 48-bit MIFARE key packed in a Long -> 6 big-endian bytes. */
    fun keyBytes(k: Long): ByteArray = ByteArray(6) { ((k shr ((5 - it) * 8)) and 0xFF).toByte() }
}

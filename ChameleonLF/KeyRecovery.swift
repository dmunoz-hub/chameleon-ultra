//  KeyRecovery.swift
//  Swift wrapper over the C Crypto1 solvers (solver_shim.c), exposed via the
//  bridging header. These run the firmware's own nested / staticnested / darkside
//  algorithms natively on-device.

import Foundation

enum KeyRecovery {
    private static let maxKeys = 64

    static func nested(uid: UInt32, dist: UInt32, nts: [UInt32], ntEncs: [UInt32], pars: [UInt8]) -> [UInt64] {
        var out = [UInt64](repeating: 0, count: maxKeys)
        let count = sv_nested(uid, dist, nts, ntEncs, pars, Int32(nts.count), &out, Int32(maxKeys))
        return Array(out.prefix(Int(max(0, count))))
    }

    static func staticNested(uid: UInt32, type: UInt8, nts: [UInt32], ntEncs: [UInt32]) -> [UInt64] {
        var out = [UInt64](repeating: 0, count: maxKeys)
        let count = sv_staticnested(uid, type, nts, ntEncs, Int32(nts.count), &out, Int32(maxKeys))
        return Array(out.prefix(Int(max(0, count))))
    }

    static func darkside(uid: UInt32, nts: [UInt32], ksLists: [UInt64], parLists: [UInt64],
                         nrs: [UInt32], ars: [UInt32]) -> [UInt64] {
        var out = [UInt64](repeating: 0, count: maxKeys)
        let count = sv_darkside(uid, nts, ksLists, parLists, nrs, ars, Int32(nts.count), &out, Int32(maxKeys))
        return Array(out.prefix(Int(max(0, count))))
    }

    /// A 48-bit MIFARE key packed in a uint64 -> 6 big-endian bytes.
    static func keyBytes(_ k: UInt64) -> [UInt8] {
        (0..<6).map { UInt8((k >> (UInt64(5 - $0) * 8)) & 0xFF) }
    }
}

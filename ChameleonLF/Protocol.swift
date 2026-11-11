//  Protocol.swift
//  Chameleon Ultra wire protocol: frame build/parse, LRC, command IDs, responses.
//
//  Frame (all multi-byte fields big-endian):
//    SOF(0x11) | LRC1(0xEF) | CMD(2) | STATUS(2) | LEN(2) | LRC2 | DATA[LEN] | LRC3
//    LRC2 covers CMD..LEN (6 bytes). LRC3 covers DATA.
//    LRC of a byte run = (0x100 - (sum of bytes)) & 0xFF.
//
//  Command IDs and payload layouts are ported from the firmware's Python CLI:
//    RfidResearchGroup/ChameleonUltra  software/script/chameleon_cmd.py + chameleon_enum.py

import Foundation

// MARK: - Commands (verbatim values from chameleon_enum.py Command enum)

enum Command: UInt16 {
    case getAppVersion          = 1000
    case changeDeviceMode       = 1001
    case getDeviceMode          = 1002
    case setActiveSlot          = 1003
    case setSlotTagType         = 1004
    case setSlotEnable          = 1006
    case slotDataConfigSave     = 1009
    case getDeviceChipId        = 1011
    case getActiveSlot          = 1018
    case getSlotInfo            = 1019
    case getEnabledSlots        = 1023
    case getBatteryInfo         = 1025
    case hf14aSetAntiColl       = 4001
    case em410xSetEmuId         = 5000

    case hf14aScan              = 2000
    case mf1DetectPrng          = 2002
    case mf1StaticNestedAcquire = 2003
    case mf1DarksideAcquire     = 2004
    case mf1DetectNtDist        = 2005
    case mf1NestedAcquire       = 2006
    case mf1AuthOneKeyBlock     = 2007
    case mf1ReadOneBlock        = 2008
    case mf1WriteOneBlock       = 2009
    case hf14aRaw               = 2010
    case mf1CheckKeysOnBlock    = 2015

    case em410xScan             = 3000
    case em410xWriteToT55xx     = 3001
}

// MARK: - Status (verbatim values from chameleon_enum.py Status enum)

enum DeviceStatus: UInt16 {
    case hfTagOk          = 0x00
    case hfTagNotFound    = 0x01
    case mfErrAuth        = 0x06
    case lfTagOk          = 0x40
    case lfTagNotFound    = 0x41
    case parErr           = 0x60
    case deviceModeError  = 0x66
    case invalidCmd       = 0x67
    case success          = 0x68
    case notImplemented   = 0x69
    case unknown          = 0xFFFF

    var label: String {
        switch self {
        case .hfTagOk:         return "HF tag OK"
        case .hfTagNotFound:   return "no HF tag"
        case .mfErrAuth:       return "MIFARE auth failed"
        case .lfTagOk:         return "LF tag OK"
        case .lfTagNotFound:   return "no LF tag"
        case .parErr:          return "parity error"
        case .deviceModeError: return "wrong device mode"
        case .invalidCmd:      return "invalid command"
        case .success:         return "success"
        case .notImplemented:  return "not implemented"
        case .unknown:         return "unknown status"
        }
    }
}

// MARK: - MIFARE key type (verbatim from chameleon_enum.py MfcKeyType)

enum MifareKeyType: UInt8 {
    case keyA = 0x60
    case keyB = 0x61
}

// MARK: - Frame builder / LRC

enum ChameleonFrame {
    static let sof: UInt8 = 0x11
    static let sofLRC: UInt8 = 0xEF

    /// LRC = (0x100 - sum) & 0xFF
    static func lrc(_ bytes: [UInt8]) -> UInt8 {
        var sum: UInt8 = 0
        for b in bytes { sum = sum &+ b }
        return UInt8((0x100 - Int(sum)) & 0xFF)
    }

    /// Build a complete request frame for a command + payload.
    static func build(_ cmd: Command, status: UInt16 = 0, data: [UInt8] = []) -> [UInt8] {
        let raw = cmd.rawValue
        let len = UInt16(data.count)
        let head: [UInt8] = [
            UInt8(raw >> 8),    UInt8(raw & 0xFF),
            UInt8(status >> 8), UInt8(status & 0xFF),
            UInt8(len >> 8),    UInt8(len & 0xFF),
        ]
        var frame: [UInt8] = [sof, sofLRC]
        frame.append(contentsOf: head)
        frame.append(lrc(head))
        frame.append(contentsOf: data)
        frame.append(lrc(data))
        return frame
    }
}

// MARK: - Response

struct ChameleonResponse {
    let cmd: UInt16
    let status: UInt16
    let data: [UInt8]

    var statusEnum: DeviceStatus { DeviceStatus(rawValue: status) ?? .unknown }

    /// HF commands report success as HF_TAG_OK (0x00).
    var hfOk: Bool { status == DeviceStatus.hfTagOk.rawValue }
    /// LF commands report success as LF_TAG_OK (0x40).
    var lfOk: Bool { status == DeviceStatus.lfTagOk.rawValue }
    /// Config / device commands report success as SUCCESS (0x68).
    var genericOk: Bool { status == DeviceStatus.success.rawValue }

    var hex: String { ChameleonFrame.hexSpaced(data) }
}

// MARK: - Hex helpers

extension ChameleonFrame {
    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
    static func hexSpaced(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    static func hex(_ byte: UInt8) -> String { String(format: "%02X", byte) }
}

// MARK: - Streaming frame parser

/// Accumulates bytes from BLE notifications and extracts complete frames.
/// Resynchronises on bad SOF/LRC so a corrupt packet can't wedge the stream.
final class FrameBuffer {
    private var buf: [UInt8] = []

    func append(_ bytes: [UInt8]) { buf.append(contentsOf: bytes) }

    func reset() { buf.removeAll() }

    /// Returns the next complete frame, or nil if more bytes are needed.
    func nextFrame() -> ChameleonResponse? {
        while true {
            // Drop anything before a SOF.
            guard let start = buf.firstIndex(of: ChameleonFrame.sof) else {
                buf.removeAll()
                return nil
            }
            if start > 0 { buf.removeFirst(start) }

            // Need the fixed 9-byte header before we can know the length.
            if buf.count < 9 { return nil }

            // Validate SOF LRC.
            if buf[1] != ChameleonFrame.sofLRC {
                buf.removeFirst(1); continue
            }

            let cmd    = UInt16(buf[2]) << 8 | UInt16(buf[3])
            let status = UInt16(buf[4]) << 8 | UInt16(buf[5])
            let len    = Int(buf[6]) << 8 | Int(buf[7])

            let head = Array(buf[2...7])
            if ChameleonFrame.lrc(head) != buf[8] {
                buf.removeFirst(1); continue
            }

            let total = 9 + len + 1 // header + data + data LRC
            if buf.count < total { return nil } // wait for the rest

            let data = Array(buf[9 ..< 9 + len])
            let dataLRC = buf[9 + len]
            if ChameleonFrame.lrc(data) != dataLRC {
                buf.removeFirst(1); continue
            }

            buf.removeFirst(total)
            return ChameleonResponse(cmd: cmd, status: status, data: data)
        }
    }
}

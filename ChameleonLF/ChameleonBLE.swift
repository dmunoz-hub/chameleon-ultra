//  ChameleonBLE.swift
//  Core Bluetooth transport for the Chameleon Ultra's Nordic UART Service (NUS).
//
//  Key rules (from the build brief, which fix the "won't connect" problems):
//   - Scan by service UUID, not by name. The device doesn't reliably advertise a name.
//   - It's a plain GATT connection, not iOS classic pairing. Don't pair in Settings.
//   - Enable notifications on TX; keep RX for writes.
//   - Info.plist must contain NSBluetoothAlwaysUsageDescription (see Info.plist).

import Foundation
import CoreBluetooth

enum BLEError: Error, LocalizedError {
    case bluetoothOff
    case scanTimeout
    case connectFailed(String)
    case serviceNotFound
    case notReady
    case responseTimeout
    case busy

    var errorDescription: String? {
        switch self {
        case .bluetoothOff:          return "Bluetooth is off or unauthorized."
        case .scanTimeout:           return "No Chameleon found. Wake the device and try again."
        case .connectFailed(let m):  return "Connection failed: \(m)"
        case .serviceNotFound:       return "Nordic UART Service not found. Toggle Bluetooth off/on."
        case .notReady:              return "Not connected."
        case .responseTimeout:       return "Device did not respond in time."
        case .busy:                  return "A command is already in progress."
        }
    }
}

final class ChameleonBLE: NSObject, ObservableObject {

    // Nordic UART Service UUIDs.
    static let nusService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rxCharUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // app -> device (write)
    static let txCharUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // device -> app (notify)

    @Published private(set) var isConnected = false
    @Published private(set) var statusText = "Idle"

    /// Called for every log line (frames in/out, state changes). Hooked by the controller.
    var onLog: ((String) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?
    private var txChar: CBCharacteristic?
    private let buffer = FrameBuffer()

    private var connectCont: CheckedContinuation<Void, Error>?
    private var responseCont: CheckedContinuation<ChameleonResponse, Error>?
    private var poweredOnConts: [CheckedContinuation<Void, Never>] = []

    override init() {
        super.init()
        // Delivering on the main queue keeps @Published updates on the main thread.
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func log(_ s: String) { onLog?(s) }

    // MARK: - Public API

    func connect(timeout: TimeInterval = 15) async throws {
        await waitPoweredOn()
        guard central.state == .poweredOn else { throw BLEError.bluetoothOff }

        if isConnected { return }

        statusText = "Scanning…"
        log("Scanning for NUS service…")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.connectCont = cont
            central.scanForPeripherals(withServices: [Self.nusService], options: nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let c = self.connectCont else { return }
                self.connectCont = nil
                self.central.stopScan()
                self.statusText = "Scan timed out"
                c.resume(throwing: BLEError.scanTimeout)
            }
        }
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    /// Send a command and await the matching response. One command at a time.
    func send(_ cmd: Command, status: UInt16 = 0, data: [UInt8] = [],
              timeout: TimeInterval = 5) async throws -> ChameleonResponse {
        guard isConnected, let rx = rxChar, let peripheral = peripheral else { throw BLEError.notReady }
        guard responseCont == nil else { throw BLEError.busy }

        let frame = ChameleonFrame.build(cmd, status: status, data: data)
        log("→ [\(cmd)] \(ChameleonFrame.hexSpaced(frame))")

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ChameleonResponse, Error>) in
            self.responseCont = cont
            buffer.reset()
            writeFrame(frame, to: rx, peripheral: peripheral)

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let c = self.responseCont else { return }
                self.responseCont = nil
                c.resume(throwing: BLEError.responseTimeout)
            }
        }
    }

    // MARK: - Internals

    private func waitPoweredOn() async {
        if central.state == .poweredOn { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            poweredOnConts.append(c)
        }
    }

    private func writeFrame(_ frame: [UInt8], to rx: CBCharacteristic, peripheral: CBPeripheral) {
        // Prefer write-with-response when the characteristic supports it (flow-controlled, reliable).
        let writeType: CBCharacteristicWriteType =
            rx.properties.contains(.write) ? .withResponse : .withoutResponse
        let maxLen = max(20, peripheral.maximumWriteValueLength(for: writeType))

        let data = Data(frame)
        var idx = 0
        while idx < data.count {
            let end = min(idx + maxLen, data.count)
            peripheral.writeValue(data.subdata(in: idx ..< end), for: rx, type: writeType)
            idx = end
        }
    }

    private func finishConnect(_ result: Result<Void, Error>) {
        guard let c = connectCont else { return }
        connectCont = nil
        switch result {
        case .success:          c.resume()
        case .failure(let e):   c.resume(throwing: e)
        }
    }

    private func failResponse(_ error: Error) {
        guard let c = responseCont else { return }
        responseCont = nil
        c.resume(throwing: error)
    }
}

// MARK: - CBCentralManagerDelegate

extension ChameleonBLE: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("Bluetooth ready.")
            let conts = poweredOnConts; poweredOnConts.removeAll()
            conts.forEach { $0.resume() }
        case .poweredOff:
            statusText = "Bluetooth off"
            isConnected = false
            finishConnect(.failure(BLEError.bluetoothOff))
            failResponse(BLEError.bluetoothOff)
        case .unauthorized:
            statusText = "Bluetooth not authorized"
            finishConnect(.failure(BLEError.bluetoothOff))
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        log("Found device (RSSI \(RSSI)). Connecting…")
        statusText = "Connecting…"
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Connected. Discovering services…")
        peripheral.discoverServices([Self.nusService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        statusText = "Connect failed"
        finishConnect(.failure(BLEError.connectFailed(error?.localizedDescription ?? "unknown")))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        statusText = "Disconnected"
        rxChar = nil; txChar = nil
        log("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? ".")")
        finishConnect(.failure(BLEError.connectFailed("disconnected")))
        failResponse(BLEError.notReady)
    }
}

// MARK: - CBPeripheralDelegate

extension ChameleonBLE: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.nusService }) else {
            finishConnect(.failure(BLEError.serviceNotFound))
            return
        }
        peripheral.discoverCharacteristics([Self.rxCharUUID, Self.txCharUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            if ch.uuid == Self.rxCharUUID { rxChar = ch }
            if ch.uuid == Self.txCharUUID { txChar = ch }
        }
        guard let tx = txChar, rxChar != nil else {
            finishConnect(.failure(BLEError.serviceNotFound))
            return
        }
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.txCharUUID else { return }
        if characteristic.isNotifying, rxChar != nil {
            isConnected = true
            statusText = "Connected"
            log("Ready.")
            finishConnect(.success(()))
        } else if let error {
            finishConnect(.failure(BLEError.connectFailed(error.localizedDescription)))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.txCharUUID, let value = characteristic.value else { return }
        buffer.append([UInt8](value))
        while let resp = buffer.nextFrame() {
            log("← cmd \(resp.cmd)  status 0x\(String(format: "%04X", resp.status)) (\(resp.statusEnum.label))  data \(resp.hex)")
            if let c = responseCont {
                responseCont = nil
                c.resume(returning: resp)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { log("Write error: \(error.localizedDescription)") }
    }
}

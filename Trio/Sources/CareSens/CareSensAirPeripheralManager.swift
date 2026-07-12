//
//  CareSensAirPeripheralManager.swift
//  Loop
//
//  CoreBluetooth driver for the CareSens Air CGM. Implements the real GATT
//  connection + handshake sequence (see caresens_protocol_spec.md):
//  discover → read sensor-info → AES handshake (0xC0 0x01) → appID (0xC0 0x03)
//  → time sync (0xC3 0x02) → enable glucose notify → request records → parse.
//

import Foundation
import CoreBluetooth
import os.log

protocol CareSensAirPeripheralManagerDelegate: AnyObject {
    func peripheralManager(_ manager: CareSensAirPeripheralManager, didReceive record: CareSensAirProtocol.GlucoseRecord)
    func peripheralManager(_ manager: CareSensAirPeripheralManager, didChangeState state: CareSensAirPeripheralManager.State)
    func peripheralManager(_ manager: CareSensAirPeripheralManager, didError message: String)
}

final class CareSensAirPeripheralManager: NSObject {

    enum State: String {
        case bluetoothOff
        case scanning
        case connecting
        case handshaking
        case running
        case disconnected
    }

    private let log = OSLog(subsystem: "org.nightscout.trio", category: "CareSensAir")

    /// 12-char sensor serial (e.g. "C1QBT5A01157").
    private let serial: String
    /// Whether the sensor has been paired with this app before (affects appID isFirst flag).
    private var isFirstConnection: Bool
    /// Number of u16 glucose values emitted per report packet (SDK field `A`).
    private let glucoseValueCount: Int

    weak var delegate: CareSensAirPeripheralManagerDelegate?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?

    private var commandWriteChar: CBCharacteristic?   // C4DE9EE4
    private var appIdAuthChar: CBCharacteristic?      // C4DEC61C
    private var glucoseNotifyChar: CBCharacteristic?  // C4DE9B74
    private var sensorInfoFirstChar: CBCharacteristic? // C4DE7E96

    // Serialized write queue (CoreBluetooth allows one outstanding write-with-response).
    private var writeQueue: [(Data, CBCharacteristic)] = []
    private var writeInProgress = false

    private(set) var state: State = .disconnected {
        didSet {
            os_log("state → %{public}@", log: log, type: .info, state.rawValue)
            delegate?.peripheralManager(self, didChangeState: state)
        }
    }

    init(serial: String, isFirstConnection: Bool, glucoseValueCount: Int = 1) {
        self.serial = serial
        self.isFirstConnection = isFirstConnection
        self.glucoseValueCount = glucoseValueCount
        super.init()
        central = CBCentralManager(delegate: self, queue: DispatchQueue(label: "com.loopkit.Loop.CareSensAir"))
    }

    /// The BLE local name this serial advertises as ("CSair <last4>").
    private var expectedLocalName: String {
        CareSensAirProtocol.transmitterNamePrefix + String(serial.suffix(4))
    }

    func start() {
        if central.state == .poweredOn { beginScan() }
    }

    func stop() {
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        state = .disconnected
    }

    private func beginScan() {
        state = .scanning
        central.scanForPeripherals(withServices: [CareSensAirProtocol.cgmServiceUUID], options: nil)
    }

    private func fail(_ message: String) {
        os_log("error: %{public}@", log: log, type: .error, message)
        delegate?.peripheralManager(self, didError: message)
    }
}

// MARK: - CBCentralManagerDelegate

extension CareSensAirPeripheralManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: beginScan()
        case .poweredOff, .unauthorized, .unsupported: state = .bluetoothOff
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Match the specific transmitter by advertised local name. Compare
        // case-insensitively so the "CSair"/"CSAir" spelling variants both match.
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard advName.caseInsensitiveCompare(expectedLocalName) == .orderedSame else { return }

        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([
            CareSensAirProtocol.sensorInfoServiceUUID,
            CareSensAirProtocol.cgmServiceUUID,
            CareSensAirProtocol.commandServiceUUID
        ])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        state = .disconnected
        // Auto-reconnect: resume scanning.
        if self.central.state == .poweredOn { beginScan() }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail("connect failed: \(error?.localizedDescription ?? "unknown")")
        beginScan()
    }
}

// MARK: - CBPeripheralDelegate

extension CareSensAirPeripheralManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            fail("service discovery failed"); return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let chars = service.characteristics else { return }
        for c in chars {
            switch c.uuid {
            case CareSensAirProtocol.commandWriteUUID:    commandWriteChar = c
            case CareSensAirProtocol.appIdAuthUUID:
                appIdAuthChar = c
                peripheral.setNotifyValue(true, for: c)
            case CareSensAirProtocol.glucoseNotifyUUID:   glucoseNotifyChar = c
            case CareSensAirProtocol.sensorInfoFirstReadUUID: sensorInfoFirstChar = c
            default: break
            }
        }
        // Once all three services' characteristics are known, kick off the sequence
        // by reading the first sensor-info characteristic (as the official app does).
        if commandWriteChar != nil, appIdAuthChar != nil, glucoseNotifyChar != nil,
           let first = sensorInfoFirstChar, state != .handshaking, state != .running {
            state = .handshaking
            peripheral.readCharacteristic(first)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }

        switch characteristic.uuid {
        case CareSensAirProtocol.sensorInfoFirstReadUUID:
            // Sensor-info read complete → send AES handshake.
            sendHandshake()

        case CareSensAirProtocol.appIdAuthUUID:
            handleAppIdEcho(value)

        case CareSensAirProtocol.glucoseNotifyUUID:
            handleGlucoseNotify(value)

        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writeInProgress = false
        if let error = error {
            fail("write failed on \(characteristic.uuid): \(error.localizedDescription)")
        }
        pumpWriteQueue()
    }

    // MARK: Write queue

    private func enqueueWrite(_ data: Data, to characteristic: CBCharacteristic) {
        writeQueue.append((data, characteristic))
        pumpWriteQueue()
    }

    private func pumpWriteQueue() {
        guard !writeInProgress, !writeQueue.isEmpty, let peripheral = peripheral else { return }
        let (data, characteristic) = writeQueue.removeFirst()
        writeInProgress = true
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    // MARK: Handshake steps

    private func sendHandshake() {
        guard let writeChar = commandWriteChar, let appChar = appIdAuthChar,
              let handshake = CareSensAirProtocol.handshakeCommand(serial: serial) else {
            fail("could not build handshake"); return
        }
        enqueueWrite(handshake, to: writeChar)
        enqueueWrite(CareSensAirProtocol.appIdCommand(isFirstConnection: isFirstConnection), to: appChar)
    }

    private func handleAppIdEcho(_ value: Data) {
        switch CareSensAirProtocol.validateAppIdEcho(value) {
        case .ok:
            isFirstConnection = false
            sendTimeSyncAndSubscribe()
        case .deviceLimit:   fail("device change limit exceeded")
        case .appIdMismatch: fail("app-ID mismatch")
        case .reconnectFail: fail("reconnect failed")
        case .malformed:     break // ignore non-echo notifications
        }
    }

    private func sendTimeSyncAndSubscribe() {
        guard let writeChar = commandWriteChar, let notifyChar = glucoseNotifyChar else { return }
        peripheral?.setNotifyValue(true, for: notifyChar)
        enqueueWrite(CareSensAirProtocol.timeSyncCommand(), to: writeChar)
        enqueueWrite(CareSensAirProtocol.recordCountCommand(), to: notifyChar)
        enqueueWrite(CareSensAirProtocol.reportRecordsCommand(), to: notifyChar)
        state = .running
    }

    private func handleGlucoseNotify(_ value: Data) {
        guard value.count >= 2 else { return }
        if value[0] == 0xC5, value[1] == 0x01,
           let record = CareSensAirProtocol.parseGlucosePacket(value, valueCount: glucoseValueCount) {
            delegate?.peripheralManager(self, didReceive: record)
        }
        // 0xC4 0x01 (record count) is informational; ignored for live use.
    }
}

private extension CBPeripheral {
    /// Small wrapper to keep call sites readable.
    func readCharacteristic(_ characteristic: CBCharacteristic) {
        readValue(for: characteristic)
    }
}

//
//  CareSensAirProtocol.swift
//  Loop
//
//  BLE protocol for the CareSens Air (i-SENS) CGM.
//  Constants, crypto, command builders, and packet parsing verified against the
//  decompiled official app (engine `ed/x0.java`) and the GATT trace `CSAir 4588.csv`.
//  See caresens_protocol_spec.md for the full specification.
//

import Foundation
import CoreBluetooth
import CommonCrypto

enum CareSensAirProtocol {

    // MARK: - BLE UUIDs

    /// CGM service; contains the glucose notify characteristic.
    static let cgmServiceUUID       = CBUUID(string: "C4DE9A20-5A9D-11E9-8647-D663BD873D93")
    /// Glucose data stream (Notify); also written to request stored records.
    static let glucoseNotifyUUID    = CBUUID(string: "C4DE9B74-5A9D-11E9-8647-D663BD873D93")

    /// Command service; contains the write + appID characteristics.
    static let commandServiceUUID   = CBUUID(string: "C4DE9DC2-5A9D-11E9-8647-D663BD873D93")
    /// Command write channel (AES handshake, time sync).
    static let commandWriteUUID     = CBUUID(string: "C4DE9EE4-5A9D-11E9-8647-D663BD873D93")
    /// App-ID / auth channel (write + notify echo).
    static let appIdAuthUUID        = CBUUID(string: "C4DEC61C-5A9D-11E9-8647-D663BD873D93")

    /// Sensor-info service; first read char kicks off the connection sequence.
    static let sensorInfoServiceUUID = CBUUID(string: "C4DE7BDA-5A9D-11E9-8647-D663BD873D93")
    static let sensorInfoFirstReadUUID = CBUUID(string: "C4DE7E96-5A9D-11E9-8647-D663BD873D93")

    /// Advertised transmitter local-name prefix: "CSair <last4-of-serial>".
    static let transmitterNamePrefix = "CSair "

    /// Fixed first 8 characters of every sensor serial; only the last 4 digits
    /// vary per device and they equal the digits in the Bluetooth name ("CSair 1157").
    static let serialPrefix = "C1QBT5A0"

    /// Builds the full 12-char serial from the 4 digits shown in the Bluetooth
    /// device name. Returns nil unless `last4` is exactly 4 digits.
    static func serial(fromLast4 last4: String) -> String? {
        let digits = last4.trimmingCharacters(in: .whitespaces)
        guard digits.count == 4, digits.allSatisfy({ $0.isNumber }) else { return nil }
        return serialPrefix + digits
    }

    // MARK: - Fixed credentials (from decompiled app)

    /// AES-256 key passed to `ConnectSensor`. 32 bytes → AES-256 (not AES-128).
    static let aesKey = Data("tq1Tg265o4UFD8tfPvNqUCiYyCxkhdZV".utf8)
    /// Fixed application id.
    static let applicationId = "csair"

    // MARK: - Command opcodes

    private static let CMD_HANDSHAKE: [UInt8]   = [0xC0, 0x01]
    private static let CMD_APPID: [UInt8]        = [0xC0, 0x03]
    private static let CMD_TIME_SYNC: [UInt8]    = [0xC3, 0x02]
    private static let CMD_RECORD_COUNT: [UInt8] = [0xC4, 0x01]
    private static let CMD_REPORT_RECORDS: [UInt8] = [0xC5, 0x01]

    // MARK: - Crypto

    /// Derives the 16-byte AES IV from the serial: suffix6 + suffix6 + suffix4.
    /// e.g. "C1QBT5A01157" -> "A01157" + "A01157" + "1157" = "A01157A011571157".
    static func iv(forSerial serial: String) -> Data {
        let s = Array(serial)
        func suffix(_ n: Int) -> String { String(s.suffix(n)) }
        return Data((suffix(6) + suffix(6) + suffix(4)).utf8)
    }

    /// AES-256-CBC / PKCS7 encryption used for the serial-auth handshake.
    static func aesCBCEncrypt(_ plaintext: Data, key: Data, iv: Data) -> Data? {
        var out = Data(count: plaintext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            plaintext.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCEncrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count,
                                ivPtr.baseAddress,
                                inPtr.baseAddress, plaintext.count,
                                outPtr.baseAddress, outPtr.count,
                                &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(moved..<out.count)
        return out
    }

    // MARK: - Command builders

    /// `[0xC0,0x01] + AES_CBC(serial)` — 18 bytes. Written to `commandWriteUUID`.
    static func handshakeCommand(serial: String) -> Data? {
        guard let cipher = aesCBCEncrypt(Data(serial.utf8), key: aesKey, iv: iv(forSerial: serial)) else {
            return nil
        }
        var data = Data(CMD_HANDSHAKE)
        data.append(cipher)
        return data
    }

    /// `[0xC0,0x03] + "csair" padded to 32 bytes with 0x00 + [isFirst]` — 35 bytes.
    /// Written to `appIdAuthUUID`.
    static func appIdCommand(isFirstConnection: Bool) -> Data {
        var data = Data(CMD_APPID)
        var idBytes = Array(applicationId.utf8)
        idBytes.append(contentsOf: Array(repeating: 0, count: 32 - idBytes.count))
        data.append(contentsOf: idBytes.prefix(32))
        data.append(isFirstConnection ? 0x01 : 0x00)
        return data
    }

    /// `[0xC3,0x02] + uint32LE(now)` — 6 bytes. Written to `commandWriteUUID`.
    static func timeSyncCommand(date: Date = Date()) -> Data {
        let t = UInt32(date.timeIntervalSince1970)
        var data = Data(CMD_TIME_SYNC)
        data.append(UInt8(t & 0xFF))
        data.append(UInt8((t >> 8) & 0xFF))
        data.append(UInt8((t >> 16) & 0xFF))
        data.append(UInt8((t >> 24) & 0xFF))
        return data
    }

    /// `[0xC4,0x01]` — request number of stored records. Written to `glucoseNotifyUUID`.
    static func recordCountCommand() -> Data { Data(CMD_RECORD_COUNT) }

    /// `[0xC5,0x01]` — request record reporting. Written to `glucoseNotifyUUID`.
    static func reportRecordsCommand() -> Data { Data(CMD_REPORT_RECORDS) }

    // MARK: - App-ID echo validation

    enum AppIdResult { case ok, deviceLimit, appIdMismatch, reconnectFail, malformed }

    /// Validates the `[0xC0,0x03, 32-byte appId, result]` echo on `appIdAuthUUID`.
    static func validateAppIdEcho(_ data: Data) -> AppIdResult {
        guard data.count >= 35, data[0] == 0xC0, data[1] == 0x03 else { return .malformed }
        switch data[data.count - 1] {
        case 0: return .ok
        case 1: return .deviceLimit
        case 2: return .appIdMismatch
        case 3: return .reconnectFail
        default: return .malformed
        }
    }

    // MARK: - Glucose packet parsing

    struct GlucoseRecord {
        /// Sensor sequence number.
        let sequence: Int
        /// Measurement time (sensor clock, unix seconds).
        let measurementTime: Date
        /// Battery raw value (0–4095).
        let batteryRaw: Int
        /// Temperature in °C.
        let temperature: Double
        /// Glucose values in mg/dL (realtime first, then trend history).
        let glucoseValues: [Int]

        /// The current (most recent) glucose value in mg/dL.
        var currentGlucose: Int? { glucoseValues.first }
    }

    /// Parses a `0xC5 0x01` reporting packet (plaintext, little-endian) into a record.
    /// `valueCount` is the number of trailing u16 glucose values the sensor emits per packet
    /// (field `A` in the SDK); pass the negotiated count (defaults to 1 = realtime only).
    static func parseGlucosePacket(_ data: Data, valueCount: Int = 1, firmwareAtLeast1_3: Bool = true) -> GlucoseRecord? {
        guard data.count >= 2, data[0] == 0xC5, data[1] == 0x01 else { return nil }
        var r = LEReader(data, offset: 2)

        if firmwareAtLeast1_3 {
            _ = r.u8()          // flags
            _ = r.u8()          // r_count
            _ = r.i32()         // adcCount
            _ = r.i32()         // reserved
        }
        guard let seq = r.i32() else { return nil }
        guard let mtime = r.i32() else { return nil }
        guard let battery = r.u16() else { return nil }
        guard let temp = r.u16() else { return nil }

        var values: [Int] = []
        for _ in 0..<max(1, valueCount) {
            guard let g = r.u16() else { break }
            values.append(g)
        }
        guard !values.isEmpty else { return nil }

        var measured = Date(timeIntervalSince1970: TimeInterval(UInt32(bitPattern: Int32(mtime))))
        // Sensor clock not yet set (year 1970) → fall back to now.
        if measured.timeIntervalSince1970 < 946_684_800 { measured = Date() }

        return GlucoseRecord(sequence: seq,
                             measurementTime: measured,
                             batteryRaw: battery,
                             temperature: Double(temp) / 100.0,
                             glucoseValues: values)
    }

    /// Parses a `0xC4 0x01` count packet → number of stored records.
    static func parseRecordCount(_ data: Data) -> Int? {
        guard data.count >= 4, data[0] == 0xC4, data[1] == 0x01 else { return nil }
        return Int(data[2]) | (Int(data[3]) << 8)
    }

    // MARK: - Trend

    /// Maps a glucose rate (mg/dL/min) to a CareSens trend index (1…7); nil if unknown.
    static func trendIndex(rateMgdlPerMin rate: Double) -> Int? {
        if rate == 100 { return nil }
        if rate > 3 { return 7 }
        if rate > 2 { return 6 }
        if rate > 1 { return 5 }
        if rate >= -1 { return 4 }
        if rate >= -2 { return 3 }
        if rate >= -3 { return 2 }
        return 1
    }
}

/// Minimal little-endian byte reader.
private struct LEReader {
    private let data: Data
    private var offset: Int
    init(_ data: Data, offset: Int) { self.data = data; self.offset = offset }

    private mutating func take(_ n: Int) -> [UInt8]? {
        guard offset + n <= data.count else { return nil }
        let start = data.startIndex + offset
        let bytes = Array(data[start..<start + n])
        offset += n
        return bytes
    }
    mutating func u8() -> Int? { take(1).map { Int($0[0]) } }
    mutating func u16() -> Int? { take(2).map { Int($0[0]) | (Int($0[1]) << 8) } }
    mutating func i32() -> Int? {
        guard let b = take(4) else { return nil }
        let v = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
        return Int(Int32(bitPattern: v))
    }
}

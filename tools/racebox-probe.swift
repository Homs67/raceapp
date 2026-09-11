// Live protocol probe for RaceBox devices (BLE Protocol doc rev 9).
// Scans → connects → reads Device Info → subscribes UART TX → decodes
// 0xFF 0x01 data messages → asks for recording status (0xFF 0x22).
import Foundation
import CoreBluetooth

let uartService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
let uartRx = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // write
let uartTx = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // notify
let infoService = CBUUID(string: "180A")
let infoChars: [CBUUID: String] = [
    CBUUID(string: "2A24"): "Model",
    CBUUID(string: "2A25"): "Serial",
    CBUUID(string: "2A26"): "Firmware",
    CBUUID(string: "2A27"): "Hardware",
    CBUUID(string: "2A29"): "Manufacturer",
]

func checksum(_ body: [UInt8]) -> (UInt8, UInt8) {
    var a: UInt8 = 0, b: UInt8 = 0
    for byte in body { a = a &+ byte; b = b &+ a }
    return (a, b)
}

func frame(cls: UInt8, id: UInt8, payload: [UInt8] = []) -> Data {
    var body: [UInt8] = [cls, id, UInt8(payload.count & 0xFF), UInt8(payload.count >> 8)]
    body += payload
    let (a, b) = checksum(body)
    return Data([0xB5, 0x62] + body + [a, b])
}

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var device: CBPeripheral?
    var rx: CBCharacteristic?
    var buffer = [UInt8]()
    var dataCount = 0
    var firstPacketAt: Date?
    var printed = 0
    var sawAck = false
    var info: [String: String] = [:]

    func start() { central = CBCentralManager(delegate: self, queue: nil) }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            print("Bluetooth ready — scanning for RaceBox…")
            c.scanForPeripherals(withServices: nil)
        case .unauthorized: fail("Bluetooth permission denied for this process")
        case .poweredOff: fail("Bluetooth is off")
        default: break
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard name.hasPrefix("RaceBox") else { return }
        c.stopScan()
        print("Found: \"\(name)\"  RSSI \(rssi) dBm  id \(p.identifier)")
        device = p
        p.delegate = self
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        print("Connected. Discovering services…")
        p.discoverServices([uartService, infoService])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        fail("connect failed: \(error?.localizedDescription ?? "unknown")")
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for service in p.services ?? [] {
            print("Service \(service.uuid)")
            p.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if s.uuid == infoService, infoChars[ch.uuid] != nil { p.readValue(for: ch) }
            if ch.uuid == uartTx {
                print("  TX \(ch.uuid) props \(ch.properties.rawValue) → subscribing")
                p.setNotifyValue(true, for: ch)
            }
            if ch.uuid == uartRx {
                print("  RX \(ch.uuid) props \(ch.properties.rawValue)")
                rx = ch
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let value = ch.value else { return }
        if let label = infoChars[ch.uuid] {
            let text = String(data: value, encoding: .utf8) ?? "?"
            info[label] = text
            print("  \(label): \(text)")
            if info.count == infoChars.count { askRecordingStatus(p) }
            return
        }
        guard ch.uuid == uartTx else { return }
        buffer.append(contentsOf: value)
        drain()
    }

    func askRecordingStatus(_ p: CBPeripheral) {
        guard let rx else { return }
        let packet = frame(cls: 0xFF, id: 0x22)
        print("\nAsking for recording status: \(packet.map { String(format: "%02X", $0) }.joined(separator: " "))")
        p.writeValue(packet, for: rx, type: .withResponse)
    }

    func drain() {
        while true {
            guard let start = (0..<max(0, buffer.count - 1)).first(where: { buffer[$0] == 0xB5 && buffer[$0 + 1] == 0x62 })
            else { if buffer.count > 4096 { buffer.removeAll() }; return }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 8 else { return }
            let length = Int(buffer[4]) | Int(buffer[5]) << 8
            let total = 6 + length + 2
            guard buffer.count >= total else { return }
            let packet = Array(buffer[0..<total])
            buffer.removeFirst(total)
            let (a, b) = checksum(Array(packet[2..<(total - 2)]))
            guard a == packet[total - 2], b == packet[total - 1] else {
                print("  ✗ checksum mismatch on class \(String(format: "%02X %02X", packet[2], packet[3]))")
                continue
            }
            handle(cls: packet[2], id: packet[3], payload: Array(packet[6..<(total - 2)]))
        }
    }

    func handle(cls: UInt8, id: UInt8, payload: [UInt8]) {
        switch (cls, id) {
        case (0xFF, 0x01):
            dataCount += 1
            if firstPacketAt == nil { firstPacketAt = Date() }
            if printed < 3 || dataCount % 25 == 0 { printData(payload); printed += 1 }
        case (0xFF, 0x22):
            print("\n✓ Recording status reply (\(payload.count) bytes):")
            guard payload.count >= 12 else { print("  short payload"); break }
            let stored = u32(payload, 4), size = u32(payload, 8)
            print("  recording: \(payload[0] != 0 ? "YES" : "no")   memory level: \(payload[1])%")
            print("  security: enabled=\(payload[2] & 1 != 0) unlocked=\(payload[2] & 2 != 0)")
            print("  stored: \(stored) of \(size) messages (\(String(format: "%.1f", Double(stored) / Double(max(size, 1)) * 100))%)")
            sawAck = true
        case (0xFF, 0x02): print("  ACK for \(String(format: "%02X %02X", payload.first ?? 0, payload.count > 1 ? payload[1] : 0))"); sawAck = true
        case (0xFF, 0x03): print("  NACK for \(String(format: "%02X %02X", payload.first ?? 0, payload.count > 1 ? payload[1] : 0))"); sawAck = true
        default: print("  other message class \(String(format: "%02X %02X", cls, id)) len \(payload.count)")
        }
    }

    func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o+1]) << 8 | UInt32(b[o+2]) << 16 | UInt32(b[o+3]) << 24
    }
    func i32(_ b: [UInt8], _ o: Int) -> Int32 { Int32(bitPattern: u32(b, o)) }
    func i16(_ b: [UInt8], _ o: Int) -> Int16 { Int16(bitPattern: UInt16(b[o]) | UInt16(b[o+1]) << 8) }
    func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o+1]) << 8 }

    func printData(_ p: [UInt8]) {
        guard p.count == 80 else { print("  data message with unexpected size \(p.count)"); return }
        let fix = p[20], flags = p[21], sats = p[23]
        let lon = Double(i32(p, 24)) / 1e7, lat = Double(i32(p, 28)) / 1e7
        let msl = Double(i32(p, 36)) / 1000
        let hAcc = Double(u32(p, 40)) / 1000
        let speed = Double(i32(p, 48)) / 1000 * 3.6
        let heading = Double(i32(p, 52)) / 1e5
        let volt = p[67]
        let gx = Double(i16(p, 68)) / 1000, gy = Double(i16(p, 70)) / 1000, gz = Double(i16(p, 72)) / 1000
        let rx_ = Double(i16(p, 74)) / 100, ry = Double(i16(p, 76)) / 100, rz = Double(i16(p, 78)) / 100
        let stamp = String(format: "%04d-%02d-%02d %02d:%02d:%02d",
                           Int(u16(p, 4)), Int(p[6]), Int(p[7]), Int(p[8]), Int(p[9]), Int(p[10]))
        print(String(format: """
          #%d  %@ UTC  fix=%d(%@) sats=%d  pdop=%.2f
              lat %.7f  lon %.7f  msl %.1fm  hAcc %.2fm
              speed %.2f km/h  heading %.2f°   input %.1fV (raw 0x%02X)
              G  x %+.3f  y %+.3f  z %+.3f g
              rot x %+.2f  y %+.2f  z %+.2f °/s
          """, dataCount, stamp, Int(fix), (flags & 1) != 0 ? "valid" : "no-fix", Int(sats),
             Double(u16(p, 64)) / 100, lat, lon, msl, hAcc, speed, heading,
             Double(volt) / 10, Int(volt), gx, gy, gz, rx_, ry, rz))
    }

    func finish() {
        if let first = firstPacketAt, dataCount > 1 {
            let hz = Double(dataCount - 1) / Date().timeIntervalSince(first)
            print(String(format: "\nRATE: %d data messages, %.1f Hz", dataCount, hz))
        } else {
            print("\nNo data messages received.")
        }
        print("Write path verified: \(sawAck ? "YES (device replied)" : "no reply seen")")
        if let d = device { central.cancelPeripheralConnection(d) }
        exit(dataCount > 0 ? 0 : 2)
    }

    func fail(_ message: String) { print("ERROR: \(message)"); exit(1) }
}

// Mirror stdout to a log file so `open`-launched runs are readable.
let logURL = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-alex-Git-raceApp/d83c892b-938d-485e-a670-acbaa183f89f/scratchpad/probe-live.txt")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let logHandle = try? FileHandle(forWritingTo: logURL)
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let line = items.map { "\($0)" }.joined(separator: separator) + terminator
    logHandle?.write(line.data(using: .utf8)!)
    try? logHandle?.synchronize()
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
}

let probe = Probe()
probe.start()
let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 12 : 12
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { probe.finish() }
RunLoop.main.run()

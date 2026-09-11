import Foundation

/// One RaceBox protocol packet in u-blox UBX binary form:
///
/// ```
/// B5 62 | class id | length (u16 LE) | payload | CK_A CK_B
/// ```
///
/// Per the RaceBox BLE Protocol doc (rev 9). All multi-byte values little-endian.
public struct RaceBoxPacket: Equatable, Sendable {

    public static let syncA: UInt8 = 0xB5
    public static let syncB: UInt8 = 0x62
    /// Device buffers cap the whole packet at 512 bytes.
    public static let maxPayloadLength = 504

    public let messageClass: UInt8
    public let messageID: UInt8
    public let payload: [UInt8]

    public init(messageClass: UInt8, messageID: UInt8, payload: [UInt8] = []) {
        self.messageClass = messageClass
        self.messageID = messageID
        self.payload = payload
    }

    /// Known message identities. RaceBox uses class 0xFF throughout.
    public enum Kind: Equatable, Sendable {
        case liveData          // FF 01 — 80-byte sensor message, up to 25 Hz
        case ack               // FF 02
        case nack              // FF 03
        case historyData       // FF 21 — same payload as liveData
        case recordingStatus   // FF 22
        case dataDownload      // FF 23
        case memoryErase       // FF 24
        case recordingConfig   // FF 25
        case recordingState    // FF 26
        case gnssConfig        // FF 27
        case unlockMemory      // FF 30
        case unknown(UInt8, UInt8)
    }

    public var kind: Kind {
        guard messageClass == 0xFF else { return .unknown(messageClass, messageID) }
        switch messageID {
        case 0x01: return .liveData
        case 0x02: return .ack
        case 0x03: return .nack
        case 0x21: return .historyData
        case 0x22: return .recordingStatus
        case 0x23: return .dataDownload
        case 0x24: return .memoryErase
        case 0x25: return .recordingConfig
        case 0x26: return .recordingState
        case 0x27: return .gnssConfig
        case 0x30: return .unlockMemory
        default: return .unknown(messageClass, messageID)
        }
    }

    /// Fletcher-8 checksum over class, id, length and payload (doc §Packets Format).
    public static func checksum<C: Collection>(_ bytes: C) -> (a: UInt8, b: UInt8)
    where C.Element == UInt8 {
        var a: UInt8 = 0
        var b: UInt8 = 0
        for byte in bytes {
            a = a &+ byte
            b = b &+ a
        }
        return (a, b)
    }

    /// Full wire bytes including header and checksum.
    public func encoded() -> Data {
        var body: [UInt8] = [messageClass, messageID,
                             UInt8(payload.count & 0xFF), UInt8((payload.count >> 8) & 0xFF)]
        body.append(contentsOf: payload)
        let sums = Self.checksum(body)
        return Data([Self.syncA, Self.syncB] + body + [sums.a, sums.b])
    }
}

/// Reassembles packets from BLE notifications.
///
/// A notification may carry a partial packet, exactly one, or several plus a
/// fragment of the next — the protocol doc is explicit that clients MUST buffer
/// and reassemble. Resyncs on the `B5 62` header and validates every checksum,
/// counting failures so the debug view can prove the link is clean.
public struct RaceBoxPacketParser: Sendable {

    /// Discard the buffer if it grows past this without yielding a packet
    /// (garbage stream or a wildly wrong length field).
    private static let bufferLimit = 8192

    private var buffer: [UInt8] = []

    public private(set) var packetsParsed = 0
    public private(set) var checksumFailures = 0
    /// Bytes dropped while hunting for a valid header — non-zero means the
    /// stream was corrupted or we joined mid-packet.
    public private(set) var bytesDiscarded = 0

    public init() {}

    /// Feed raw bytes; returns every complete, checksum-valid packet found.
    public mutating func feed(_ data: Data) -> [RaceBoxPacket] {
        buffer.append(contentsOf: data)
        var packets: [RaceBoxPacket] = []

        while true {
            guard let syncIndex = findSync() else {
                // No header at all — keep at most one trailing byte, which may
                // be the first half of a header split across notifications.
                if buffer.count > 1 {
                    bytesDiscarded += buffer.count - 1
                    buffer.removeFirst(buffer.count - 1)
                }
                break
            }
            if syncIndex > 0 {
                bytesDiscarded += syncIndex
                buffer.removeFirst(syncIndex)
            }
            guard buffer.count >= 6 else { break } // need the length field

            let length = Int(buffer[4]) | Int(buffer[5]) << 8
            guard length <= RaceBoxPacket.maxPayloadLength else {
                // Impossible length: this "header" is noise — resync past it.
                dropSync()
                continue
            }
            let total = 6 + length + 2
            guard buffer.count >= total else { break } // wait for the rest

            let sums = RaceBoxPacket.checksum(buffer[2..<(total - 2)])
            guard sums.a == buffer[total - 2], sums.b == buffer[total - 1] else {
                checksumFailures += 1
                dropSync() // don't trust `length` from a corrupt packet
                continue
            }

            packets.append(RaceBoxPacket(messageClass: buffer[2], messageID: buffer[3],
                                         payload: Array(buffer[6..<(total - 2)])))
            packetsParsed += 1
            buffer.removeFirst(total)
        }

        if buffer.count > Self.bufferLimit {
            bytesDiscarded += buffer.count
            buffer.removeAll(keepingCapacity: true)
        }
        return packets
    }

    /// Index of the next `B5 62` header, if any.
    private func findSync() -> Int? {
        guard buffer.count >= 2 else { return nil }
        for i in 0...(buffer.count - 2) where buffer[i] == RaceBoxPacket.syncA && buffer[i + 1] == RaceBoxPacket.syncB {
            return i
        }
        return nil
    }

    /// Step past a bad header so the next scan can find a real one.
    private mutating func dropSync() {
        bytesDiscarded += 2
        buffer.removeFirst(min(2, buffer.count))
    }
}

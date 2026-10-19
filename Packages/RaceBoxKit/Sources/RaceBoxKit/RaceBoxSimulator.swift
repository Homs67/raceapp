import Foundation
import BleKit

/// One synthetic sample to encode into a RaceBox data message.
public struct RaceBoxSample: Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitudeMeters: Double
    public var speedMps: Double
    public var headingDegrees: Double
    public var gForce: RaceBoxVector3
    public var rotationRate: RaceBoxVector3
    public var satellites: Int
    public var hasFix: Bool
    public var date: Date

    public init(latitude: Double = 36.5844, longitude: Double = -121.7536,
                altitudeMeters: Double = 30, speedMps: Double = 0,
                headingDegrees: Double = 0,
                gForce: RaceBoxVector3 = RaceBoxVector3(x: 0, y: 0, z: 1),
                rotationRate: RaceBoxVector3 = RaceBoxVector3(x: 0, y: 0, z: 0),
                satellites: Int = 12, hasFix: Bool = true, date: Date = Date()) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMeters = altitudeMeters
        self.speedMps = speedMps
        self.headingDegrees = headingDegrees
        self.gForce = gForce
        self.rotationRate = rotationRate
        self.satellites = satellites
        self.hasFix = hasFix
        self.date = date
    }
}

/// Builds wire-format RaceBox packets from synthetic samples — the inverse of
/// `RaceBoxDataMessage`, used by demo mode, simulator screenshots, and the
/// round-trip tests that prove encode/decode agree.
public enum RaceBoxEncoder {

    public static func dataMessage(_ sample: RaceBoxSample,
                                   model: RaceBoxModel = .micro,
                                   powerByte: UInt8? = nil,
                                   messageID: UInt8 = 0x01) -> RaceBoxPacket {
        var payload = [UInt8](repeating: 0, count: RaceBoxDataMessage.payloadSize)

        func put(_ value: UInt32, _ offset: Int) {
            payload[offset] = UInt8(value & 0xFF)
            payload[offset + 1] = UInt8((value >> 8) & 0xFF)
            payload[offset + 2] = UInt8((value >> 16) & 0xFF)
            payload[offset + 3] = UInt8((value >> 24) & 0xFF)
        }
        func put(_ value: Int32, _ offset: Int) { put(UInt32(bitPattern: value), offset) }
        func put16(_ value: UInt16, _ offset: Int) {
            payload[offset] = UInt8(value & 0xFF)
            payload[offset + 1] = UInt8((value >> 8) & 0xFF)
        }
        func put16(_ value: Int16, _ offset: Int) { put16(UInt16(bitPattern: value), offset) }
        func clampedI16(_ value: Double) -> Int16 {
            Int16(max(Double(Int16.min), min(Double(Int16.max), value.rounded())))
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                            from: sample.date)

        // iTOW: ms since the start of the GPS week (Sunday 00:00 UTC)
        let weekday: Int = calendar.component(.weekday, from: sample.date) - 1
        let hourSeconds: Int = (parts.hour ?? 0) * 3600
        let minuteSeconds: Int = (parts.minute ?? 0) * 60
        let secondsToday: Int = hourSeconds + minuteSeconds + (parts.second ?? 0)
        let weekMilliseconds: Int = (weekday * 86_400 + secondsToday) * 1000
        put(UInt32(weekMilliseconds), 0)

        put16(UInt16(parts.year ?? 2026), 4)
        payload[6] = UInt8(parts.month ?? 1)
        payload[7] = UInt8(parts.day ?? 1)
        payload[8] = UInt8(parts.hour ?? 0)
        payload[9] = UInt8(parts.minute ?? 0)
        payload[10] = UInt8(parts.second ?? 0)
        payload[11] = 0x07                      // date + time valid, fully resolved
        put(UInt32(25), 12)                     // time accuracy 25 ns
        put(Int32(0), 16)                       // nanoseconds
        payload[20] = sample.hasFix ? 3 : 0     // 3D fix
        // bit 0 valid fix; bit 5 valid heading, which a real receiver only
        // asserts once there is motion to derive a course from.
        let headingValid = sample.hasFix && sample.speedMps > 0.5
        payload[21] = (sample.hasFix ? 0x01 : 0) | (headingValid ? 0x20 : 0)
        payload[22] = sample.hasFix ? 0xEA : 0  // date/time confirmed
        payload[23] = UInt8(min(255, max(0, sample.satellites)))

        put(Int32((sample.longitude * 1e7).rounded()), 24)
        put(Int32((sample.latitude * 1e7).rounded()), 28)
        put(Int32((sample.altitudeMeters * 1000).rounded()), 32)   // WGS
        put(Int32((sample.altitudeMeters * 1000).rounded()), 36)   // MSL
        put(UInt32(900), 40)                    // 0.9 m horizontal accuracy
        put(UInt32(1800), 44)                   // 1.8 m vertical accuracy
        put(Int32((sample.speedMps * 1000).rounded()), 48)
        put(Int32((sample.headingDegrees * 1e5).rounded()), 52)
        put(UInt32(200), 56)
        put(UInt32(500_000), 60)
        put16(UInt16(120), 64)                  // PDOP 1.20
        payload[66] = sample.hasFix ? 0 : 1     // bit 0 set = coordinates invalid
        payload[67] = powerByte ?? (model.reportsInputVoltage ? 0x79 : 0x59) // 12.1 V / 89 %

        put16(clampedI16(sample.gForce.x * 1000), 68)
        put16(clampedI16(sample.gForce.y * 1000), 70)
        put16(clampedI16(sample.gForce.z * 1000), 72)
        put16(clampedI16(sample.rotationRate.x * 100), 74)
        put16(clampedI16(sample.rotationRate.y * 100), 76)
        put16(clampedI16(sample.rotationRate.z * 100), 78)

        return RaceBoxPacket(messageClass: 0xFF, messageID: messageID, payload: payload)
    }
}

/// A `BleTransport` that behaves like a RaceBox: streams synthetic data
/// messages at a fixed rate and answers the commands we send it. Lets the whole
/// stack — session, debug view, recording — run with no hardware.
public final class RaceBoxSimulatedTransport: BleTransport, @unchecked Sendable {

    public var incoming: AsyncStream<Data> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            subscribers[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.subscribers[id] = nil
                self.lock.unlock()
            }
        }
    }

    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<Data>.Continuation] = [:]
    private var pumpTask: Task<Void, Never>?

    private let model: RaceBoxModel
    private let rate: RaceBoxDataRate
    /// Source of truth for what the simulated device is "seeing".
    private let sampleProvider: @Sendable () -> RaceBoxSample
    private var recordingConfig = RaceBoxRecordingConfig(enabled: false)
    private var downloadTask: Task<Void, Never>?

    /// Synthetic stored memory, so the download and import path can be
    /// exercised without hardware. Two drives: the first ends with a proper
    /// stop marker, the second simply stops — a device unplugged mid-drive
    /// leaves no marker, and the importer has to split on the time gap.
    public var storedRecordsPerDrive = 300
    public var storedDriveCount = 2
    /// Split notifications mid-packet to exercise the reassembly path — this is
    /// how a real device behaves at low MTU.
    public var notificationChunkSize: Int?

    public init(model: RaceBoxModel = .micro,
                rate: RaceBoxDataRate = .hz25,
                sampleProvider: @escaping @Sendable () -> RaceBoxSample = { RaceBoxSample() }) {
        self.model = model
        self.rate = rate
        self.sampleProvider = sampleProvider
    }

    deinit { pumpTask?.cancel() }

    /// Start streaming live data, as a real device does on subscribe.
    public func start() {
        guard pumpTask == nil else { return }
        let interval = Duration.seconds(1 / rate.hz)
        pumpTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                let packet = RaceBoxEncoder.dataMessage(self.sampleProvider(), model: self.model)
                self.emit(packet.encoded())
            }
        }
    }

    public func stop() {
        pumpTask?.cancel()
        pumpTask = nil
    }

    public func send(_ data: Data) async throws {
        var parser = RaceBoxPacketParser()
        for packet in parser.feed(data) {
            respond(to: packet)
        }
    }

    private func respond(to packet: RaceBoxPacket) {
        switch packet.kind {
        case .recordingStatus where packet.payload.isEmpty:
            guard model.supportsStandaloneRecording else { return nack(packet) }
            let stored: UInt32 = 67_173
            let size: UInt32 = 196_608
            var payload: [UInt8] = [recordingConfig.enabled ? 1 : 0,
                                    UInt8(stored * 100 / size), 0, 0]
            for value in [stored, size] {
                payload.append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                                            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
            }
            emit(RaceBoxPacket(messageClass: 0xFF, messageID: 0x22, payload: payload).encoded())

        case .recordingConfig where packet.payload.isEmpty:
            emit(RaceBoxPacket(messageClass: 0xFF, messageID: 0x25,
                               payload: recordingConfig.payload).encoded())

        case .recordingConfig:
            guard model.supportsStandaloneRecording,
                  let config = RaceBoxRecordingConfig(payload: packet.payload) else { return nack(packet) }
            recordingConfig = config
            ack(packet)

        case .gnssConfig where packet.payload.isEmpty:
            emit(RaceBoxPacket(messageClass: 0xFF, messageID: 0x27,
                               payload: RaceBoxGnssConfig.automotive.payload).encoded())

        case .unlockMemory:
            ack(packet)

        case .dataDownload where packet.payload.isEmpty:
            guard model.supportsStandaloneRecording else { return nack(packet) }
            beginDownload()

        case .dataDownload:
            // Payload 0xFF = cancel.
            downloadTask?.cancel()
            downloadTask = nil
            ack(packet)

        case .memoryErase:
            guard model.supportsStandaloneRecording else { return nack(packet) }
            beginErase()

        default:
            ack(packet)
        }
    }

    /// Reply with the record count, stream the stored drives, then ack the
    /// download command — which is what tells the client it is finished.
    private func beginDownload() {
        downloadTask?.cancel()
        let total = storedRecordsPerDrive * storedDriveCount
        var countPayload = [UInt8](repeating: 0, count: 4)
        for i in 0..<4 { countPayload[i] = UInt8((UInt32(total) >> (8 * UInt32(i))) & 0xFF) }
        emit(RaceBoxPacket(messageClass: 0xFF, messageID: 0x23, payload: countPayload).encoded())

        let perDrive = storedRecordsPerDrive
        let drives = storedDriveCount
        downloadTask = Task { [weak self] in
            guard let self else { return }
            // Drives an hour apart so the importer's gap rule has something
            // to find on the boundary without a marker.
            var date = Date().addingTimeInterval(-3600 * Double(drives + 1))
            for drive in 0..<drives {
                for index in 0..<perDrive {
                    if Task.isCancelled { return }
                    let t = Double(index) / 25
                    let sample = RaceBoxSample(
                        latitude: 36.5844 + sin(t / 30) * 0.002,
                        longitude: -121.7536 + cos(t / 30) * 0.002,
                        altitudeMeters: 30,
                        speedMps: max(0, 18 + 14 * sin(t / 7)),
                        headingDegrees: (t * 6).truncatingRemainder(dividingBy: 360),
                        gForce: RaceBoxVector3(x: sin(t / 4) * 0.3, y: cos(t / 7) * 0.2, z: 1),
                        rotationRate: RaceBoxVector3(x: 0, y: 0, z: sin(t / 4) * 20),
                        satellites: 14, hasFix: true, date: date)
                    self.emit(RaceBoxEncoder.dataMessage(sample, model: self.model,
                                                         messageID: 0x21).encoded())
                    date.addTimeInterval(1 / 25)
                    if index % 50 == 0 { try? await Task.sleep(for: .milliseconds(1)) }
                }
                // Only the first drive was stopped cleanly.
                if drive == 0 {
                    var payload = [UInt8](repeating: 0, count: 12)
                    payload[0] = RaceBoxRecordingStateChange.State.disabled.rawValue
                    self.emit(RaceBoxPacket(messageClass: 0xFF, messageID: 0x26,
                                            payload: payload).encoded())
                }
                date.addTimeInterval(3600)
            }
            self.emit(RaceBoxPacket(messageClass: 0xFF, messageID: 0x02,
                                    payload: [0xFF, 0x23]).encoded())
        }
    }

    /// Erase reports progress, then acks.
    private func beginErase() {
        downloadTask?.cancel()
        downloadTask = Task { [weak self] in
            guard let self else { return }
            for percent in stride(from: 0, through: 100, by: 20) {
                if Task.isCancelled { return }
                self.emit(RaceBoxPacket(messageClass: 0xFF, messageID: 0x24,
                                        payload: [UInt8(percent)]).encoded())
                try? await Task.sleep(for: .milliseconds(80))
            }
            self.emit(RaceBoxPacket(messageClass: 0xFF, messageID: 0x02,
                                    payload: [0xFF, 0x24]).encoded())
        }
    }

    private func ack(_ packet: RaceBoxPacket) {
        emit(RaceBoxPacket(messageClass: 0xFF, messageID: 0x02,
                           payload: [packet.messageClass, packet.messageID]).encoded())
    }

    private func nack(_ packet: RaceBoxPacket) {
        emit(RaceBoxPacket(messageClass: 0xFF, messageID: 0x03,
                           payload: [packet.messageClass, packet.messageID]).encoded())
    }

    private func emit(_ data: Data) {
        lock.lock()
        let targets = Array(subscribers.values)
        let chunkSize = notificationChunkSize
        lock.unlock()
        guard let chunkSize, chunkSize > 0 else {
            for target in targets { target.yield(data) }
            return
        }
        var offset = 0
        while offset < data.count {
            let slice = data.subdata(in: offset..<min(offset + chunkSize, data.count))
            for target in targets { target.yield(slice) }
            offset += chunkSize
        }
    }
}

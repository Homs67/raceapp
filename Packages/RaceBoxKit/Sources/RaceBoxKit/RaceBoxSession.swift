import Foundation
import BleKit

public enum RaceBoxError: Error, Equatable {
    case timeout
    case rejected(messageClass: UInt8, messageID: UInt8)   // device sent NACK
    case transportClosed
    case unsupported(String)
    case malformedReply
}

/// Link health, surfaced by the debug view to prove reassembly is correct.
public struct RaceBoxLinkStats: Equatable, Sendable {
    public var packetsParsed = 0
    public var dataMessages = 0
    public var checksumFailures = 0
    public var bytesDiscarded = 0
    public var largestNotification = 0
    /// Measured live-data rate over a trailing window.
    public var measuredHz: Double = 0
    public init() {}
}

/// Talks the RaceBox protocol over a BLE serial transport: reassembles packets,
/// publishes live data messages, and runs commands with ACK/NACK correlation.
///
/// One command at a time (serial lock) — actor reentrancy alone would let two
/// commands clobber each other's reply slot, which is exactly the bug that
/// broke ELM327 diagnostics.
public actor RaceBoxSession {

    private let transport: any BleTransport
    private var parser = RaceBoxPacketParser()
    private var readerTask: Task<Void, Never>?

    /// Live data fan-out — one continuation per consumer (the dashboard and the
    /// recorder both subscribe). A single shared stream would die with its
    /// first consumer.
    private var liveSubscribers: [UUID: AsyncStream<RaceBoxDataMessage>.Continuation] = [:]
    /// History messages during a memory download, plus recording-state markers.
    private var historySubscribers: [UUID: AsyncStream<RaceBoxHistoryEvent>.Continuation] = [:]

    private var replyWaiters: [UInt16: [CheckedContinuation<RaceBoxPacket, Error>]] = [:]
    private var isBusy = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []

    public private(set) var stats = RaceBoxLinkStats()
    private var dataTimestamps: [TimeInterval] = []

    public init(transport: any BleTransport) {
        self.transport = transport
    }

    deinit { readerTask?.cancel() }

    // MARK: - Lifecycle

    /// Begin reading. Live data starts arriving as soon as the device's notify
    /// characteristic is subscribed — no enable command is needed.
    public func start() {
        guard readerTask == nil else { return }
        readerTask = Task { [transport] in
            for await chunk in transport.incoming {
                await self.ingest(chunk)
            }
            await self.handleTransportClosed()
        }
    }

    /// Release the transport subscription and fail anything in flight. Without
    /// this the reader task pins the actor alive as a zombie subscriber.
    public func shutdown() {
        readerTask?.cancel()
        readerTask = nil
        failAllWaiters(RaceBoxError.transportClosed)
        for continuation in liveSubscribers.values { continuation.finish() }
        liveSubscribers.removeAll()
        for continuation in historySubscribers.values { continuation.finish() }
        historySubscribers.removeAll()
    }

    // MARK: - Streams

    public var liveData: AsyncStream<RaceBoxDataMessage> {
        AsyncStream { continuation in
            let id = UUID()
            liveSubscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeLiveSubscriber(id) }
            }
        }
    }

    public var historyEvents: AsyncStream<RaceBoxHistoryEvent> {
        AsyncStream { continuation in
            let id = UUID()
            historySubscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeHistorySubscriber(id) }
            }
        }
    }

    private func removeLiveSubscriber(_ id: UUID) { liveSubscribers[id] = nil }
    private func removeHistorySubscriber(_ id: UUID) { historySubscribers[id] = nil }

    // MARK: - Commands

    /// Send a command and wait for its reply — either a message of the same
    /// class/ID or an ACK/NACK naming it. NACK throws `.rejected`.
    @discardableResult
    public func execute(_ packet: RaceBoxPacket, timeout: TimeInterval = 5) async throws -> RaceBoxPacket {
        await acquireLock()
        defer { releaseLock() }

        let key = Self.key(packet.messageClass, packet.messageID)
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.failWaiters(key: key, error: RaceBoxError.timeout)
        }
        defer { timeoutTask.cancel() }

        // Register the waiter BEFORE sending. Awaiting the write first leaves a
        // window where a fast reply is routed with nobody listening — the
        // command then times out even though the device answered.
        let reply = try await withCheckedThrowingContinuation { continuation in
            replyWaiters[key, default: []].append(continuation)
            Task { [transport] in
                do {
                    try await transport.send(packet.encoded())
                } catch {
                    await self.failWaiters(key: key, error: RaceBoxError.transportClosed)
                }
            }
        }
        if let ack = RaceBoxAcknowledgement(packet: reply), !ack.isPositive {
            throw RaceBoxError.rejected(messageClass: ack.messageClass, messageID: ack.messageID)
        }
        return reply
    }

    public func recordingStatus() async throws -> RaceBoxRecordingStatus {
        let reply = try await execute(RaceBoxCommand.recordingStatusRequest())
        guard let status = RaceBoxRecordingStatus(payload: reply.payload) else {
            throw RaceBoxError.malformedReply
        }
        return status
    }

    public func recordingConfig() async throws -> RaceBoxRecordingConfig {
        let reply = try await execute(RaceBoxCommand.recordingConfigRequest())
        guard let config = RaceBoxRecordingConfig(payload: reply.payload) else {
            throw RaceBoxError.malformedReply
        }
        return config
    }

    public func setRecording(_ config: RaceBoxRecordingConfig) async throws {
        try await execute(RaceBoxCommand.setRecording(config))
    }

    public func stopRecording() async throws {
        try await execute(RaceBoxCommand.stopRecording())
    }

    public func unlockMemory(code: UInt32) async throws {
        try await execute(RaceBoxCommand.unlockMemory(code: code))
    }

    public func gnssConfig() async throws -> RaceBoxGnssConfig {
        let reply = try await execute(RaceBoxCommand.gnssConfigRequest())
        guard let config = RaceBoxGnssConfig(payload: reply.payload) else {
            throw RaceBoxError.malformedReply
        }
        return config
    }

    /// Begin a memory dump; returns the expected record count. History records
    /// then arrive on `historyEvents` until `.finished`. Live data is suspended
    /// by the device for the duration.
    public func startDownload() async throws -> UInt32 {
        let reply = try await execute(RaceBoxCommand.startDownload(), timeout: 10)
        guard let count = RaceBoxCommand.downloadRecordCount(payload: reply.payload) else {
            throw RaceBoxError.malformedReply
        }
        return count
    }

    public func cancelDownload() async throws {
        try await execute(RaceBoxCommand.cancelDownload(), timeout: 10)
    }

    /// Erase all stored records. Progress arrives on `historyEvents` as
    /// `.eraseProgress`; a full erase can take minutes.
    public func eraseMemory() async throws {
        try await execute(RaceBoxCommand.eraseMemory(), timeout: 180)
    }

    // MARK: - Ingest

    private func ingest(_ chunk: Data) {
        stats.largestNotification = max(stats.largestNotification, chunk.count)
        let packets = parser.feed(chunk)
        stats.packetsParsed = parser.packetsParsed
        stats.checksumFailures = parser.checksumFailures
        stats.bytesDiscarded = parser.bytesDiscarded
        for packet in packets { route(packet) }
    }

    private func route(_ packet: RaceBoxPacket) {
        switch packet.kind {
        case .liveData:
            guard let message = RaceBoxDataMessage(payload: packet.payload) else { return }
            stats.dataMessages += 1
            noteDataRate()
            for continuation in liveSubscribers.values { continuation.yield(message) }

        case .historyData:
            guard let message = RaceBoxDataMessage(payload: packet.payload) else { return }
            emitHistory(.record(message))

        case .recordingState:
            if let change = RaceBoxRecordingStateChange(payload: packet.payload) {
                emitHistory(.stateChange(change))
            }

        case .memoryErase:
            if let progress = RaceBoxCommand.eraseProgress(payload: packet.payload) {
                emitHistory(.eraseProgress(percent: progress))
                return // progress notification, not a command reply
            }
            resumeWaiters(for: packet)

        case .ack, .nack:
            guard let ack = RaceBoxAcknowledgement(packet: packet) else { return }
            if ack.messageClass == 0xFF, ack.messageID == 0x23, ack.isPositive {
                emitHistory(.finished)
            }
            resumeWaiters(key: Self.key(ack.messageClass, ack.messageID), with: packet)

        default:
            resumeWaiters(for: packet)
        }
    }

    private func emitHistory(_ event: RaceBoxHistoryEvent) {
        for continuation in historySubscribers.values { continuation.yield(event) }
    }

    private func noteDataRate() {
        let now = monotonicSeconds()
        dataTimestamps.append(now)
        dataTimestamps.removeAll { now - $0 > 3 }
        if let first = dataTimestamps.first, dataTimestamps.count > 1, now > first {
            stats.measuredHz = Double(dataTimestamps.count - 1) / (now - first)
        }
    }

    // MARK: - Waiters

    private static func key(_ messageClass: UInt8, _ messageID: UInt8) -> UInt16 {
        UInt16(messageClass) << 8 | UInt16(messageID)
    }

    private func resumeWaiters(for packet: RaceBoxPacket) {
        resumeWaiters(key: Self.key(packet.messageClass, packet.messageID), with: packet)
    }

    private func resumeWaiters(key: UInt16, with packet: RaceBoxPacket) {
        guard let waiters = replyWaiters.removeValue(forKey: key) else { return }
        for waiter in waiters { waiter.resume(returning: packet) }
    }

    private func failWaiters(key: UInt16, error: Error) {
        guard let waiters = replyWaiters.removeValue(forKey: key) else { return }
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    private func failAllWaiters(_ error: Error) {
        let all = replyWaiters.values.flatMap { $0 }
        replyWaiters.removeAll()
        for waiter in all { waiter.resume(throwing: error) }
    }

    private func handleTransportClosed() {
        failAllWaiters(RaceBoxError.transportClosed)
    }

    // MARK: - Serial lock

    private func acquireLock() async {
        while isBusy {
            await withCheckedContinuation { continuation in
                lockWaiters.append(continuation)
            }
        }
        isBusy = true
    }

    private func releaseLock() {
        isBusy = false
        guard !lockWaiters.isEmpty else { return }
        let next = lockWaiters.removeFirst()
        next.resume()
    }
}

/// Events emitted while downloading stored data or erasing memory.
public enum RaceBoxHistoryEvent: Sendable {
    case record(RaceBoxDataMessage)
    /// Start / stop / pause marker — splits a dump into separate drives.
    case stateChange(RaceBoxRecordingStateChange)
    case eraseProgress(percent: Int)
    case finished
}

/// Monotonic clock shared with the rest of the app's sample timestamps.
public func monotonicSeconds() -> TimeInterval {
    TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

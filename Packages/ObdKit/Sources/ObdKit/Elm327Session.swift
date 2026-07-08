import Foundation

public enum ElmError: Error, Equatable {
    case noData
    case stopped
    case unableToConnect
    case canError
    case busError
    case unknownCommand
    case timeout
    case transportClosed
}

public struct ElmInfo: Sendable, Equatable {
    public let version: String
}

/// ECU capability map discovered on first connect, persisted with the car profile.
public struct SupportedPids: Sendable, Equatable {
    public let pids: Set<UInt8>
    public init(pids: Set<UInt8>) { self.pids = pids }
    public func supports(_ channel: ObdChannel) -> Bool { pids.contains(channel.pid) }
    public func supports(_ pid: UInt8) -> Bool { pids.contains(pid) }
}

/// Serializes commands to the ELM327 and assembles its responses.
/// One command in flight at a time; responses are accumulated until the '>' prompt,
/// tolerating arbitrary chunking, echoes, and interleaved "SEARCHING..." lines.
public actor Elm327Session {

    private let transport: any ObdTransport
    private var readerTask: Task<Void, Never>?
    private var pending = ""
    private var waiter: (id: Int, continuation: CheckedContinuation<String, Error>)?
    private var nextWaiterId = 0

    // Serial command lock. Actors are reentrant — while one execute() is
    // suspended awaiting its response, the actor is free to run another
    // execute(), which would clobber `waiter`. This gate guarantees exactly one
    // command is truly in flight, so overlapping callers (poller + diagnostics)
    // can't corrupt each other's responses.
    private var isBusy = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []

    public init(transport: any ObdTransport) {
        self.transport = transport
    }

    private func lock() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { lockWaiters.append($0) }
        // Resumed by unlock() with ownership handed over; isBusy stays true.
    }

    private func unlock() {
        if lockWaiters.isEmpty {
            isBusy = false
        } else {
            lockWaiters.removeFirst().resume()
        }
    }

    deinit {
        readerTask?.cancel()
    }

    // MARK: - Command execution

    /// Send one command, await its complete response, return cleaned lines.
    @discardableResult
    public func execute(_ command: String, timeout: Duration = .seconds(3)) async throws -> [String] {
        await lock()
        defer { unlock() }
        startReaderIfNeeded()
        let id = nextWaiterId
        nextWaiterId += 1

        let segment: String = try await withCheckedThrowingContinuation { continuation in
            waiter = (id, continuation)
            Task { [transport] in
                do {
                    try await transport.send(Data((command + "\r").utf8))
                } catch {
                    await self.failWaiter(id: id, error: error)
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                await self.failWaiter(id: id, error: ElmError.timeout)
            }
        }
        return try Self.parse(segment: segment, command: command)
    }

    /// AT init sequence per 03 §3. `elmProtocol` nil = auto (ATSP0);
    /// pass the persisted protocol number (6 for the ND2) on reconnect.
    public func initialize(elmProtocol: Int? = nil) async throws -> ElmInfo {
        let resetLines = try await execute("ATZ", timeout: .seconds(5))
        let version = resetLines.first(where: { $0.contains("ELM327") }) ?? resetLines.last ?? "unknown"
        for command in ["ATE0", "ATL0", "ATS0", "ATH0", "ATSP\(elmProtocol ?? 0)", "ATAT2"] {
            _ = try await execute(command)
        }
        return ElmInfo(version: version)
    }

    /// Wake the ECU and sweep the supported-PID bitmaps.
    /// Throws `.unableToConnect`/`.noData` while the ignition is off — callers
    /// treat that as the WaitingForIgnition state and retry.
    public func connectEcu() async throws -> SupportedPids {
        var supported: Set<UInt8> = []
        for basePid: UInt8 in [0x00, 0x20, 0x40, 0x60] {
            if basePid != 0x00, !supported.contains(basePid) { break }
            let command = String(format: "01%02X", basePid)
            let lines = try await execute(command, timeout: .seconds(10)) // first 0100 may SEARCH
            let bytes = PidDecoder.payloadBytes(fromLines: lines)
            guard bytes.count >= 6, bytes[0] == 0x41, bytes[1] == basePid else {
                if basePid == 0x00 { throw ElmError.unableToConnect }
                break
            }
            supported.formUnion(PidDecoder.supportedPids(basePid: basePid, bytes: Array(bytes[2...])))
        }
        return SupportedPids(pids: supported)
    }

    /// Directly probe one mode-01 PID; returns its decoded value or nil if the
    /// ECU doesn't answer. More reliable than the 0100 supported-bitmap on
    /// quirky adapters, and the source of truth for "is this channel available".
    public func probeValue(pid: UInt8) async -> Double? {
        guard let lines = try? await execute(String(format: "01%02X1", pid)) else { return nil }
        return PidDecoder.decodeMode01(lines: lines).first(where: { $0.pid == pid })?.value
    }

    /// Read the VIN (mode 09 PID 02).
    public func readVin() async throws -> String? {
        let lines = try await execute("0902", timeout: .seconds(5))
        return PidDecoder.decodeVin(lines: lines)
    }

    /// Read MIL state and stored-DTC count (mode 01 PID 01).
    public func readDtcStatus() async throws -> (milOn: Bool, dtcCount: Int)? {
        let lines = try await execute("0101", timeout: .seconds(5))
        return PidDecoder.decodeDtcStatus(lines: lines)
    }

    // MARK: - Response assembly

    private func startReaderIfNeeded() {
        guard readerTask == nil else { return }
        readerTask = Task { [transport] in
            for await chunk in transport.incoming {
                await self.ingest(chunk)
            }
            await self.failWaiter(id: nil, error: ElmError.transportClosed)
        }
    }

    private func ingest(_ chunk: Data) {
        guard let text = String(data: chunk, encoding: .ascii) else { return }
        pending += text.replacingOccurrences(of: "\0", with: "")
        while let promptIndex = pending.firstIndex(of: ">") {
            let segment = String(pending[pending.startIndex..<promptIndex])
            pending = String(pending[pending.index(after: promptIndex)...])
            deliver(segment)
        }
    }

    private func deliver(_ segment: String) {
        guard let current = waiter else { return } // unsolicited output — drop
        waiter = nil
        current.continuation.resume(returning: segment)
    }

    private func failWaiter(id: Int?, error: Error) {
        guard let current = waiter, id == nil || current.id == id else { return }
        waiter = nil
        current.continuation.resume(throwing: error)
    }

    /// Split a raw segment into lines, strip echo/noise, surface ELM error states.
    static func parse(segment: String, command: String) throws -> [String] {
        let lines = segment
            .split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { $0 != command }                        // echo (pre-ATE0)
            .filter { !$0.uppercased().hasPrefix("SEARCHING") }

        for line in lines {
            let upper = line.uppercased()
            if upper == "NO DATA" { throw ElmError.noData }
            if upper == "STOPPED" { throw ElmError.stopped }
            if upper.contains("UNABLE TO CONNECT") { throw ElmError.unableToConnect }
            if upper.contains("CAN ERROR") { throw ElmError.canError }
            if upper.contains("BUS INIT") && upper.contains("ERROR") { throw ElmError.busError }
        }
        if lines == ["?"] { throw ElmError.unknownCommand }
        return lines
    }
}

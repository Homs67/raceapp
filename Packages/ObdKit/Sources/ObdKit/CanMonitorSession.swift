import Foundation

/// Per-frame capture stats from a monitor run.
public struct CanFrameStats: Sendable {
    public let id: UInt32
    public var count: Int
    public var lastData: [UInt8]
    public var hz: Double
}

public struct CanMonitorReport: Sendable {
    public var frames: [CanFrameStats]           // per unique ID seen
    public var signals: [(key: String, name: String, unit: String, value: Double?, samples: Int)]
    public var rawLines: [String]                // small sample for on-screen display
    public var rawLog: [String] = []             // full timestamped capture for sharing

    /// Shareable plain-text report: decoded values, per-ID stats, and the full
    /// timestamped raw frame capture (so scaling can be verified offline).
    public func textReport(header: String) -> String {
        var out = ["RACEAPP · CAN MONITOR", header, ""]
        if !signals.isEmpty {
            out.append("DECODED SIGNALS")
            for s in signals {
                let value = s.value.map { String(format: "%.2f %@", $0, s.unit) } ?? "(no value)"
                out.append("  \(s.name): \(value)  [\(s.samples) frames]")
            }
            out.append("")
        }
        out.append("FRAMES SEEN (\(frames.count) IDs)")
        for f in frames {
            let bytes = f.lastData.map { String(format: "%02X", $0) }.joined(separator: " ")
            out.append(String(format: "  0x%03X  ·  %d frames  ·  %.0f Hz  ·  last: %@", f.id, f.count, f.hz, bytes))
        }
        out.append("")
        out.append("RAW CAPTURE (\(rawLog.count) lines)")
        out.append(contentsOf: rawLog)
        return out.joined(separator: "\n")
    }
}

/// Streams raw broadcast CAN frames from an ELM327 in monitor mode
/// (`AT MA`), with hardware ID filters to keep a low-end adapter from
/// overflowing. Owns the transport exclusively — run it on a dedicated
/// connection, not alongside the live PID poller.
public actor CanMonitorSession {

    private let transport: any ObdTransport
    private var readerTask: Task<Void, Never>?
    private var pending = ""
    private var buffered: [String] = []
    /// Full timestamped capture for the whole run (for the shareable log).
    private var capturedLog: [(ms: Int, line: String)] = []
    private var runStart: TimeInterval = 0

    public init(transport: any ObdTransport) {
        self.transport = transport
    }

    deinit { readerTask?.cancel() }

    /// Stop reading from the transport (see Elm327Session.shutdown —
    /// the reader task otherwise keeps this actor subscribed forever).
    public func shutdown() {
        readerTask?.cancel()
        readerTask = nil
    }

    // MARK: - Setup

    /// ELM init for raw 11-bit CAN monitoring: headers on (to see IDs), spaces
    /// on (easy parsing), formatting off (raw frames), CAN 11-bit/500k.
    public func configure() async {
        startReader()
        for command in ["ATZ", "ATE0", "ATL0", "ATS1", "ATH1", "ATCAF0", "ATSP6"] {
            clear()
            await send(command)
            try? await Task.sleep(for: command == "ATZ" ? .milliseconds(900) : .milliseconds(180))
        }
    }

    // MARK: - Monitoring

    /// Monitor each target frame ID for `perID`, round-robin (one filtered ID at
    /// a time = lowest bus load = most reliable on cheap adapters). Decodes the
    /// given signals and returns per-ID stats + a sample of raw lines.
    public func monitor(signals: [CanSignal], perID: Duration = .seconds(2)) async -> CanMonitorReport {
        beginLog()
        let ids = CanSignalMap.frameIDs(signals)
        var statsByID: [UInt32: CanFrameStats] = [:]
        var rawSample: [String] = []
        let perIDSeconds = perID.seconds

        for id in ids {
            mark(String(format: "# filter 0x%03X", id))
            let (frames, raw) = await captureOneID(id, duration: perID)
            if rawSample.count < 24 { rawSample.append(contentsOf: raw.prefix(24 - rawSample.count)) }
            for frame in frames {
                var s = statsByID[frame.id] ?? CanFrameStats(id: frame.id, count: 0, lastData: [], hz: 0)
                s.count += 1
                s.lastData = frame.data
                statsByID[frame.id] = s
            }
            if var s = statsByID[id] {
                s.hz = perIDSeconds > 0 ? Double(s.count) / perIDSeconds : 0
                statsByID[id] = s
            }
        }

        await resetFilter()

        let signalReadings = signals.map { signal -> (key: String, name: String, unit: String, value: Double?, samples: Int) in
            let stats = statsByID[signal.frameID]
            let value = stats.flatMap { $0.lastData.isEmpty ? nil : signal.decode($0.lastData) }
            return (signal.key, signal.name, signal.unit, value, stats?.count ?? 0)
        }
        return CanMonitorReport(frames: Array(statsByID.values).sorted { $0.id < $1.id },
                                signals: signalReadings, rawLines: rawSample, rawLog: takeLog())
    }

    /// Discovery: monitor ALL frames for `duration`, tally which IDs appear.
    public func scanBus(duration: Duration = .seconds(6)) async -> CanMonitorReport {
        beginLog()
        clear()
        await send("ATCM 000") // mask 0 → every frame passes
        try? await Task.sleep(for: .milliseconds(180))
        clear()
        await send("ATMA")
        try? await Task.sleep(for: duration)
        await sendRaw(" ") // any byte stops monitoring
        try? await Task.sleep(for: .milliseconds(250))

        let lines = take()
        var statsByID: [UInt32: CanFrameStats] = [:]
        for line in lines {
            guard let frame = CanFrameParser.parse(line) else { continue }
            var s = statsByID[frame.id] ?? CanFrameStats(id: frame.id, count: 0, lastData: [], hz: 0)
            s.count += 1
            s.lastData = frame.data
            statsByID[frame.id] = s
        }
        let seconds = duration.seconds
        for id in Array(statsByID.keys) {
            if var s = statsByID[id] {
                s.hz = seconds > 0 ? Double(s.count) / seconds : 0
                statsByID[id] = s
            }
        }
        await resetFilter()
        return CanMonitorReport(frames: Array(statsByID.values).sorted { $0.count > $1.count },
                                signals: [], rawLines: Array(lines.prefix(24)), rawLog: takeLog())
    }

    // MARK: - Internals

    private func captureOneID(_ id: UInt32, duration: Duration) async -> (frames: [CanFrame], raw: [String]) {
        clear()
        await send("ATCM 7FF")                       // all 11 bits must match
        try? await Task.sleep(for: .milliseconds(140))
        await send(String(format: "ATCF %03X", id))  // pass only this ID
        try? await Task.sleep(for: .milliseconds(140))
        clear()
        await send("ATMA")
        try? await Task.sleep(for: duration)
        await sendRaw(" ")
        try? await Task.sleep(for: .milliseconds(220))
        let lines = take()
        let frames = lines.compactMap { CanFrameParser.parse($0) }.filter { $0.id == id }
        return (frames, lines)
    }

    private func resetFilter() async {
        clear()
        await send("ATCM 000")
        try? await Task.sleep(for: .milliseconds(120))
    }

    private func send(_ command: String) async {
        try? await transport.send(Data((command + "\r").utf8))
    }
    private func sendRaw(_ s: String) async {
        try? await transport.send(Data(s.utf8))
    }

    private func clear() { buffered.removeAll() }
    private func take() -> [String] {
        let lines = buffered
        buffered.removeAll()
        return lines
    }

    private func beginLog() {
        runStart = monotonicNow()
        capturedLog.removeAll()
    }
    private func mark(_ text: String) {
        capturedLog.append((ms: Int((monotonicNow() - runStart) * 1000), line: text))
    }
    private func takeLog() -> [String] {
        let log = capturedLog.map { entry in
            entry.line.hasPrefix("#") ? entry.line : String(format: "%6dms  %@", entry.ms, entry.line)
        }
        capturedLog.removeAll()
        return log
    }

    private func startReader() {
        guard readerTask == nil else { return }
        readerTask = Task { [transport] in
            for await chunk in transport.incoming {
                await self.ingest(chunk)
            }
        }
    }

    private func ingest(_ chunk: Data) {
        guard let text = String(data: chunk, encoding: .ascii) else { return }
        pending += text.replacingOccurrences(of: "\0", with: "")
        // Frames/responses are newline- or prompt-delimited during monitoring.
        while let idx = pending.firstIndex(where: { $0 == "\r" || $0 == "\n" || $0 == ">" }) {
            let line = String(pending[pending.startIndex..<idx]).trimmingCharacters(in: .whitespaces)
            pending = String(pending[pending.index(after: idx)...])
            if !line.isEmpty {
                buffered.append(line)
                capturedLog.append((ms: Int((monotonicNow() - runStart) * 1000), line: line))
            }
        }
    }
}

private extension Duration {
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

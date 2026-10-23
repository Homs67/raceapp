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
    /// Discovery results: truth-sample counts + auto-correlated decoder candidates.
    public var analysis: [String] = []

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
        if !analysis.isEmpty {
            out.append("DISCOVERY ANALYSIS")
            out.append(contentsOf: analysis.map { "  \($0)" })
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
    private var buffered: [(t: TimeInterval, line: String)] = []
    /// Full timestamped capture for the whole run (for the shareable log).
    /// Capped so the continuous stream mode can't grow it without bound.
    private var capturedLog: [(ms: Int, line: String)] = []
    private var runStart: TimeInterval = 0
    /// Prompts (`>`) received so far — how `send(_:awaitingPromptFor:)` knows
    /// the adapter finished with a command.
    private var promptsSeen = 0
    private static let logCap = 20_000

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

    /// Abort any active ATMA (any byte stops it) before releasing the reader,
    /// so the next ELM handshake over the same link starts from a clean prompt.
    public func stopAndShutdown() async {
        await sendRaw(" ")
        try? await Task.sleep(for: .milliseconds(150))
        shutdown()
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
        startReader()
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
    /// A 500 kbps bus overflows a cheap adapter's buffer in ~300 ms with an
    /// open filter, so the monitor restarts on every BUFFER FULL and the
    /// bursts accumulate across the whole window.
    public func scanBus(duration: Duration = .seconds(6)) async -> CanMonitorReport {
        startReader()
        beginLog()
        clear()
        await send("ATCM 000") // mask 0 → every frame passes
        try? await Task.sleep(for: .milliseconds(180))
        clear()
        var lines: [String] = []
        let deadline = monotonicNow() + duration.seconds
        await send("ATMA")
        while monotonicNow() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            let burst = take()
            lines.append(contentsOf: burst)
            if burst.contains(where: { $0.replacingOccurrences(of: " ", with: "").contains("BUFFERFULL") }) {
                await send("ATMA")
            }
        }
        await sendRaw(" ") // any byte stops monitoring
        try? await Task.sleep(for: .milliseconds(250))
        lines.append(contentsOf: take())
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

    // MARK: - Continuous recording stream

    /// One decoded reading from the continuous stream: a broadcast CAN signal,
    /// a genuinely polled OBD value from the slow-PID interlude, or a note
    /// about how the adapter is being driven (for Settings/diagnostics).
    public enum CanStreamReading: Sendable {
        case can(key: String, value: Double, t: TimeInterval)
        case obd(channel: ObdChannel, value: Double, t: TimeInterval)
        case mode(String)
        /// Diagnostics worth keeping with the session: probe verdicts, mode
        /// changes, and a tally every 30 s of frames per ID and overflows.
        case note(String)
    }

    /// One hardware filter setting: an `ATCM` mask / `ATCF` filter pair that
    /// admits every ID in `ids` (and, when they differ in some bits, other
    /// IDs too — see `admittedCount`).
    public struct FilterGroup: Hashable, Sendable {
        public let ids: [UInt32]
        public let mask: UInt32
        public let filter: UInt32

        /// The tightest single mask that passes all of `ids`: bits where every
        /// ID agrees must match; bits where they differ are don't-cares.
        public init(ids: [UInt32]) {
            let unique = Array(Set(ids)).sorted()
            var differing: UInt32 = 0
            for id in unique { differing |= id ^ (unique.first ?? 0) }
            self.ids = unique
            self.mask = ~differing & 0x7FF
            self.filter = (unique.first ?? 0) & mask
        }

        /// How many distinct 11-bit IDs the mask lets through.
        public var admittedCount: Int { 1 << (11 - mask.nonzeroBitCount) }
        public var isSingle: Bool { ids.count == 1 }
        var label: String {
            isSingle ? String(format: "0x%03X", ids[0])
                     : String(format: "mask 0x%03X/0x%03X (%d IDs)", mask, filter, ids.count)
        }
    }

    /// Continuous capture for a whole recording session.
    ///
    /// A cheap ELM327 has one hardware filter, so the fallback is to rotate it
    /// across the signal frame IDs — the frame carrying RPM gets every other
    /// slot so the live dashboard/shift lights stay fresh. Before settling for
    /// that, the stream probes whether one mask can admit every wanted ID at
    /// once without the adapter overflowing (`combineFilters`): if it can,
    /// every signal streams continuously and nothing rotates. Every
    /// `interludeEvery` seconds it pauses briefly to poll slow OBD PIDs that
    /// aren't on broadcast CAN. Runs until the consumer stops iterating or the
    /// task is cancelled.
    public func stream(signals: [CanSignal],
                       dwell: Duration = .milliseconds(250),
                       interludePids: [ObdChannel] = [.coolantTemp, .fuelLevel, .controlModuleVoltage, .engineLoad],
                       interludeEvery: TimeInterval = 60,
                       combineFilters: Bool = true,
                       probe: Duration = .milliseconds(1500),
                       minCombinedHz: Double = 5) -> AsyncStream<CanStreamReading> {
        AsyncStream { continuation in
            let task = Task {
                await self.runStream(signals: signals, dwell: dwell,
                                     interludePids: interludePids,
                                     interludeEvery: interludeEvery,
                                     combineFilters: combineFilters,
                                     probe: probe, minCombinedHz: minCombinedHz,
                                     continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// RPM's frame in every other slot: `[202, 086, 202, 078, 202, 4B0]`.
    static func rotationSchedule(for signals: [CanSignal]) -> [UInt32] {
        rotation(of: CanSignalMap.frameIDs(signals).map { FilterGroup(ids: [$0]) },
                 priority: priorityFrameID(signals)).map { $0.ids[0] }
    }

    static func priorityFrameID(_ signals: [CanSignal]) -> UInt32? {
        signals.first(where: { $0.key == "canRpm" })?.frameID
    }

    /// Interleave the group holding the priority frame between all others.
    static func rotation(of groups: [FilterGroup], priority: UInt32?) -> [FilterGroup] {
        guard groups.count > 1, let priority,
              let hot = groups.first(where: { $0.ids.contains(priority) }) else { return groups }
        var schedule: [FilterGroup] = []
        for group in groups where group != hot {
            schedule.append(hot)
            schedule.append(group)
        }
        return schedule.isEmpty ? groups : schedule
    }

    private func runStream(signals: [CanSignal], dwell: Duration,
                           interludePids: [ObdChannel], interludeEvery: TimeInterval,
                           combineFilters: Bool, probe: Duration, minCombinedHz: Double,
                           continuation: AsyncStream<CanStreamReading>.Continuation) async {
        await configure()
        let ids = CanSignalMap.frameIDs(signals)
        let priority = Self.priorityFrameID(signals)
        var schedule = await planSchedule(ids: ids, priority: priority, combine: combineFilters,
                                          probe: probe, minHz: minCombinedHz,
                                          continuation: continuation)
        continuation.yield(.mode(Self.describe(schedule, dwell: dwell)))
        continuation.yield(.note("mode: " + Self.describe(schedule, dwell: dwell)))
        var tally = StreamTally(since: monotonicNow())

        var lastInterlude = monotonicNow()
        var slot = 0
        var currentMask: UInt32? = nil
        while !Task.isCancelled {
            let group = schedule[slot % schedule.count]
            slot += 1
            await select(group, currentMask: &currentMask)
            clear()
            await send("ATMA")

            if schedule.count == 1 {
                // One filter covers everything: leave the monitor running and
                // drain it continuously. Fall back to rotating if the adapter
                // keeps overflowing or goes quiet.
                var overflows: [TimeInterval] = []
                var silentSince = monotonicNow()
                var rearms = 0
                var healthy = true
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    let lines = takeStamped()
                    if !lines.isEmpty { silentSince = monotonicNow() }
                    var overflowed = false
                    for (t, line) in lines {
                        if let frame = CanFrameParser.parse(line, t: t) {
                            emit(frame, signals: signals, tally: &tally, continuation: continuation)
                        } else if Self.isBufferFull(line) {
                            overflowed = true
                        }
                    }
                    let now = monotonicNow()
                    if let report = tally.reportIfDue(now: now) { continuation.yield(.note(report)) }
                    if overflowed {
                        tally.overflows += 1
                        overflows.append(now)
                        overflows.removeAll { now - $0 > 10 }
                        if overflows.count >= 3 { healthy = false; break }
                        await send("ATMA")
                    } else if now - silentSince > 2 {
                        rearms += 1
                        if rearms > 2 { healthy = false; break }
                        silentSince = now
                        await send("ATMA")
                    }
                    if !interludePids.isEmpty, now - lastInterlude >= interludeEvery {
                        lastInterlude = now
                        await stopMonitor()
                        await pollSlowPids(interludePids, into: continuation)
                        currentMask = nil   // the interlude moved the filter
                        break
                    }
                }
                if !healthy {
                    await stopMonitor()
                    mark("# combined filter unhealthy → rotating")
                    schedule = Self.rotation(of: ids.map { FilterGroup(ids: [$0]) }, priority: priority)
                    continuation.yield(.mode(Self.describe(schedule, dwell: dwell)))
                    continuation.yield(.note("combined filter unhealthy → " + Self.describe(schedule, dwell: dwell)))
                }
                continue
            }

            try? await Task.sleep(for: dwell)
            await stopMonitor()
            tally.slots += 1
            for (t, line) in takeStamped() {
                if Self.isBufferFull(line) { tally.overflows += 1; continue }
                guard let frame = CanFrameParser.parse(line, t: t), group.ids.contains(frame.id) else { continue }
                emit(frame, signals: signals, tally: &tally, continuation: continuation)
            }
            if let report = tally.reportIfDue(now: monotonicNow()) { continuation.yield(.note(report)) }
            if !interludePids.isEmpty, monotonicNow() - lastInterlude >= interludeEvery {
                lastInterlude = monotonicNow()
                await pollSlowPids(interludePids, into: continuation)
                currentMask = nil
            }
        }
        continuation.finish()
    }

    /// Decide how to drive the filter: everything at once if the adapter can
    /// take it, else RPM's frame alone alternating with the rest combined,
    /// else plain single-ID rotation.
    private func planSchedule(ids: [UInt32], priority: UInt32?, combine: Bool,
                              probe: Duration, minHz: Double,
                              continuation: AsyncStream<CanStreamReading>.Continuation) async -> [FilterGroup] {
        let singles = ids.map { FilterGroup(ids: [$0]) }
        guard combine, ids.count > 1 else { return Self.rotation(of: singles, priority: priority) }

        let all = FilterGroup(ids: ids)
        if await passes(all, probe: probe, minHz: minHz, continuation: continuation) { return [all] }

        if let priority, ids.count > 2 {
            let rest = FilterGroup(ids: ids.filter { $0 != priority })
            if await passes(rest, probe: probe, minHz: minHz, continuation: continuation) {
                return Self.rotation(of: [FilterGroup(ids: [priority]), rest], priority: priority)
            }
        }
        return Self.rotation(of: singles, priority: priority)
    }

    /// Run the monitor briefly through `group`'s mask and judge it: no
    /// BUFFER FULL, and every wanted ID arriving at a usable rate.
    private func passes(_ group: FilterGroup, probe: Duration, minHz: Double,
                        continuation: AsyncStream<CanStreamReading>.Continuation) async -> Bool {
        var mask: UInt32? = nil
        await select(group, currentMask: &mask)
        clear()
        await send("ATMA")
        try? await Task.sleep(for: probe)
        await stopMonitor()
        let lines = takeStamped()
        var counts: [UInt32: Int] = [:]
        var overflowed = false
        for (t, line) in lines {
            if let frame = CanFrameParser.parse(line, t: t) {
                counts[frame.id, default: 0] += 1
            } else if Self.isBufferFull(line) {
                overflowed = true
            }
        }
        let seconds = max(probe.seconds, 0.001)
        let rates = group.ids.map { Double(counts[$0] ?? 0) / seconds }
        let ok = !overflowed && rates.allSatisfy { $0 >= minHz }
        let summary = "probe \(group.label): \(ok ? "pass" : "fail")"
            + (overflowed ? " (BUFFER FULL)" : "")
            + " · " + zip(group.ids, rates).map { String(format: "0x%03X %.0f Hz", $0, $1) }.joined(separator: ", ")
            + " · \(lines.count) lines"
        mark("# " + summary)
        continuation.yield(.note(summary))
        return ok
    }

    private func select(_ group: FilterGroup, currentMask: inout UInt32?) async {
        clear()
        if currentMask != group.mask {
            await send(String(format: "ATCM %03X", group.mask), awaitingPromptFor: .milliseconds(150))
            currentMask = group.mask
        }
        await send(String(format: "ATCF %03X", group.filter), awaitingPromptFor: .milliseconds(150))
    }

    /// Any byte stops ATMA; the ELM answers STOPPED and a prompt.
    private func stopMonitor() async {
        await sendRaw(" ", awaitingPromptFor: .milliseconds(250))
    }

    /// Running counts for the periodic diagnostics note.
    private struct StreamTally {
        var since: TimeInterval
        var frames: [UInt32: Int] = [:]
        var overflows = 0
        var slots = 0

        mutating func reportIfDue(now: TimeInterval, every: TimeInterval = 30) -> String? {
            guard now - since >= every else { return nil }
            let secs = now - since
            let perID = frames.keys.sorted().map { id in
                String(format: "0x%03X %.0f Hz", id, Double(frames[id] ?? 0) / secs)
            }.joined(separator: ", ")
            let text = String(format: "%.0f s: %@%@ · BUFFER FULL ×%d · %d slots",
                              secs, perID.isEmpty ? "no frames" : perID, "", overflows, slots)
            self = StreamTally(since: now)
            return text
        }
    }

    private func emit(_ frame: CanFrame, signals: [CanSignal],
                      tally: inout StreamTally,
                      continuation: AsyncStream<CanStreamReading>.Continuation) {
        tally.frames[frame.id, default: 0] += 1
        for signal in signals where signal.frameID == frame.id {
            if let value = signal.decode(frame.data) {
                continuation.yield(.can(key: signal.key, value: value, t: frame.t))
            }
        }
    }

    static func isBufferFull(_ line: String) -> Bool {
        line.replacingOccurrences(of: " ", with: "").uppercased().contains("BUFFERFULL")
    }

    static func describe(_ schedule: [FilterGroup], dwell: Duration) -> String {
        if schedule.count == 1, let only = schedule.first {
            return only.isSingle ? "continuous, \(only.label)"
                                 : "continuous, \(only.ids.count) IDs through one mask"
        }
        let distinct = Array(Set(schedule)).count
        let combined = schedule.contains { !$0.isSingle }
        return "rotating \(distinct) filter\(distinct == 1 ? "" : "s")"
            + (combined ? " (one combined)" : "")
            + String(format: ", %.0f ms dwell", dwell.seconds * 1000)
    }

    /// Monitor is stopped; point the filter at the ECU reply ID and send raw
    /// single-frame requests (CAF is off, so the ISO-TP PCI byte is explicit).
    private func pollSlowPids(_ channels: [ObdChannel],
                              into continuation: AsyncStream<CanStreamReading>.Continuation) async {
        clear()
        await send("ATCM 7FF", awaitingPromptFor: .milliseconds(150))
        await send("ATCF 7E8", awaitingPromptFor: .milliseconds(150))
        for channel in channels {
            clear()
            await send(String(format: "02 01 %02X", channel.pid), awaitingPromptFor: .milliseconds(400))
            for (t, line) in takeStamped() {
                guard let frame = CanFrameParser.parse(line, t: t),
                      (0x7E8...0x7EF).contains(frame.id),
                      frame.data.count >= 3, frame.data[1] == 0x41, frame.data[2] == channel.pid,
                      let value = PidDecoder.decode(pid: channel.pid, bytes: Array(frame.data.dropFirst(3)))
                else { continue }
                continuation.yield(.obd(channel: channel, value: value, t: t))
                break
            }
        }
    }

    // MARK: - Discovery capture (find new signals via OBD ground truth)

    /// Alternates open-filter bursts (all broadcast IDs, BUFFER FULL re-armed)
    /// with OBD truth polls of known channels, then auto-correlates every frame
    /// byte against the truth series. Best run during warmup with occasional
    /// throttle blips so coolant/load/rpm all sweep. Results land in
    /// `analysis` + the shareable raw log.
    public func discover(duration: Duration = .seconds(180),
                         truthChannels: [ObdChannel] = [.rpm, .coolantTemp, .engineLoad,
                                                        .throttle, .acceleratorPedal,
                                                        .intakeAirTemp, .fuelLevel, .speed]) async -> CanMonitorReport {
        startReader()
        beginLog()
        var stamped: [(t: TimeInterval, line: String)] = []
        var truth: [String: [(t: TimeInterval, value: Double)]] = [:]
        let deadline = monotonicNow() + duration.seconds

        while monotonicNow() < deadline, !Task.isCancelled {
            // 1) Open-filter burst: everything the bus broadcasts.
            mark("# burst")
            clear()
            await send("ATCM 000")
            try? await Task.sleep(for: .milliseconds(120))
            clear()
            await send("ATMA")
            let burstEnd = min(deadline, monotonicNow() + 4)
            while monotonicNow() < burstEnd, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                let chunk = takeStamped()
                stamped.append(contentsOf: chunk)
                if chunk.contains(where: { $0.line.replacingOccurrences(of: " ", with: "").contains("BUFFERFULL") }) {
                    await send("ATMA")
                }
            }
            await sendRaw(" ")
            try? await Task.sleep(for: .milliseconds(200))
            stamped.append(contentsOf: takeStamped())

            // 2) Truth pass: poll known OBD channels for the correlator.
            mark("# truth")
            clear()
            await send("ATCM 7FF")
            try? await Task.sleep(for: .milliseconds(80))
            await send("ATCF 7E8")
            try? await Task.sleep(for: .milliseconds(80))
            for channel in truthChannels {
                clear()
                await send(String(format: "02 01 %02X", channel.pid))
                try? await Task.sleep(for: .milliseconds(200))
                for (t, line) in takeStamped() {
                    guard let frame = CanFrameParser.parse(line, t: t),
                          (0x7E8...0x7EF).contains(frame.id),
                          frame.data.count >= 3, frame.data[1] == 0x41, frame.data[2] == channel.pid,
                          let value = PidDecoder.decode(pid: channel.pid, bytes: Array(frame.data.dropFirst(3)))
                    else { continue }
                    truth[channel.rawValue, default: []].append((t, value))
                    break
                }
            }
        }
        await resetFilter()

        // Broadcast frames only — diagnostic request/response IDs would
        // trivially "discover" themselves.
        let frames = stamped
            .compactMap { CanFrameParser.parse($0.line, t: $0.t) }
            .filter { !(0x7E0...0x7EF).contains($0.id) }
        var statsByID: [UInt32: CanFrameStats] = [:]
        for frame in frames {
            var s = statsByID[frame.id] ?? CanFrameStats(id: frame.id, count: 0, lastData: [], hz: 0)
            s.count += 1
            s.lastData = frame.data
            statsByID[frame.id] = s
        }

        var analysis: [String] = truth
            .sorted { $0.key < $1.key }
            .map { name, samples in
                let values = samples.map(\.value)
                return String(format: "truth %@: %d samples, %.4g…%.4g",
                              name, samples.count, values.min() ?? 0, values.max() ?? 0)
            }
        let candidates = CanCorrelator.match(frames: frames, truth: truth)
        analysis.append(candidates.isEmpty
            ? "no decoder candidates (need more variation — rev, drive, or capture during warmup)"
            : "decoder candidates (truth ≈ scale·raw + offset):")
        analysis.append(contentsOf: candidates.prefix(20).map(\.summary))

        var report = CanMonitorReport(frames: Array(statsByID.values).sorted { $0.count > $1.count },
                                      signals: [], rawLines: Array(stamped.prefix(24)).map(\.line),
                                      rawLog: takeLog())
        report.analysis = analysis
        return report
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

    /// Send, then wait for the ELM's next prompt — or give up after `timeout`.
    /// Replaces fixed sleeps so filter switches cost what the link costs.
    private func send(_ command: String, awaitingPromptFor timeout: Duration) async {
        let before = promptsSeen
        await send(command)
        await awaitPrompt(after: before, timeout: timeout)
    }
    private func sendRaw(_ s: String, awaitingPromptFor timeout: Duration) async {
        let before = promptsSeen
        await sendRaw(s)
        await awaitPrompt(after: before, timeout: timeout)
    }
    private func awaitPrompt(after count: Int, timeout: Duration) async {
        let deadline = monotonicNow() + timeout.seconds
        while promptsSeen == count, monotonicNow() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func clear() { buffered.removeAll() }
    private func take() -> [String] {
        takeStamped().map(\.line)
    }
    private func takeStamped() -> [(t: TimeInterval, line: String)] {
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
            if pending[idx] == ">" { promptsSeen += 1 }
            let line = String(pending[pending.startIndex..<idx]).trimmingCharacters(in: .whitespaces)
            pending = String(pending[pending.index(after: idx)...])
            if !line.isEmpty {
                let now = monotonicNow()
                buffered.append((t: now, line: line))
                capturedLog.append((ms: Int((now - runStart) * 1000), line: line))
                if buffered.count > Self.logCap { buffered.removeFirst(Self.logCap / 2) }
                if capturedLog.count > Self.logCap { capturedLog.removeFirst(Self.logCap / 2) }
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

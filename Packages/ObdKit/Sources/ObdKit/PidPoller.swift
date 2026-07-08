import Foundation

public struct PollerConfiguration: Sendable {
    /// Channels polled continuously, together when `useMultiPid`.
    public var fastChannels: [ObdChannel]
    /// Channels rotated through slowly — one per due window.
    public var slowChannels: [ObdChannel]
    /// Target period for a full slow-channel sweep.
    public var slowSweepInterval: TimeInterval
    /// CAN allows several PIDs per request (one round-trip for the whole fast loop).
    /// Confirmed/refuted for the ND2 at the driveway spike; sequential is the fallback.
    public var useMultiPid: Bool

    public init(
        fastChannels: [ObdChannel] = ObdChannel.defaultFastLoop,
        slowChannels: [ObdChannel] = ObdChannel.defaultSlowLoop,
        slowSweepInterval: TimeInterval = 5,
        useMultiPid: Bool = true
    ) {
        self.fastChannels = fastChannels
        self.slowChannels = slowChannels
        self.slowSweepInterval = slowSweepInterval
        self.useMultiPid = useMultiPid
    }
}

/// Fast/slow-loop scheduler per 03 §4. Emits timestamped samples; drops
/// channels the ECU reports NO DATA for; never dies on a single bad response.
public actor PidPoller {

    private enum PollOutcome {
        case ok
        case noData
        case transient
    }

    private let session: Elm327Session
    private var configuration: PollerConfiguration
    private var unsupported: Set<ObdChannel> = []
    private var slowIndex = 0
    private var lastSlowPoll: TimeInterval = 0
    private var running = false

    public init(session: Elm327Session, configuration: PollerConfiguration = PollerConfiguration()) {
        self.session = session
        self.configuration = configuration
    }

    /// Restrict polling to what the ECU actually supports (from `connectEcu()`).
    public func apply(supportedPids: SupportedPids) {
        for channel in configuration.fastChannels + configuration.slowChannels
        where !supportedPids.supports(channel) {
            unsupported.insert(channel)
        }
    }

    /// Channels dropped so far (unsupported or NO DATA) — surfaced in dev UI.
    public var droppedChannels: Set<ObdChannel> { unsupported }

    /// Start polling. The stream ends (and polling stops) when the consumer
    /// terminates it or `stop()` is called.
    public func samples() -> AsyncStream<ObdSample> {
        running = true
        return AsyncStream { continuation in
            let task = Task { await self.run(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stop() {
        running = false
    }

    private func run(_ continuation: AsyncStream<ObdSample>.Continuation) async {
        while running, !Task.isCancelled {
            await pollFastLoop(continuation)
            await pollSlowChannelIfDue(continuation)
        }
        continuation.finish()
    }

    // MARK: - Fast loop

    private func pollFastLoop(_ continuation: AsyncStream<ObdSample>.Continuation) async {
        let channels = configuration.fastChannels.filter { !unsupported.contains($0) }
        guard !channels.isEmpty else {
            try? await Task.sleep(for: .milliseconds(200))
            return
        }
        if configuration.useMultiPid {
            let command = "01" + channels.map { String(format: "%02X", $0.pid) }.joined() + "1"
            do {
                let lines = try await session.execute(command)
                let timestamp = monotonicNow()
                var seen = Set<ObdChannel>()
                for (pid, value) in PidDecoder.decodeMode01(lines: lines) {
                    if let channel = ObdChannel(pid: pid) {
                        continuation.yield(ObdSample(channel: channel, value: value, timestamp: timestamp))
                        seen.insert(channel)
                    }
                }
                // Fall back to sequential if the adapter didn't batch every requested
                // PID (some ELM clones silently return only the first one or two —
                // this is why throttle went missing on the real Veepeak).
                if seen.count < channels.count {
                    configuration.useMultiPid = false
                }
            } catch ElmError.noData {
                configuration.useMultiPid = false
            } catch ElmError.stopped {
                // interrupted around reconnects — next cycle retries
            } catch {
                try? await Task.sleep(for: .milliseconds(100))
            }
        } else {
            for channel in channels {
                let command = String(format: "01%02X1", channel.pid)
                if await poll(command: command, continuation: continuation) == .noData {
                    unsupported.insert(channel)
                }
            }
        }
    }

    // MARK: - Slow loop

    private func pollSlowChannelIfDue(_ continuation: AsyncStream<ObdSample>.Continuation) async {
        let channels = configuration.slowChannels.filter { !unsupported.contains($0) }
        guard !channels.isEmpty else { return }
        let perChannelInterval = configuration.slowSweepInterval / Double(channels.count)
        let now = monotonicNow()
        guard now - lastSlowPoll >= perChannelInterval else { return }
        lastSlowPoll = now

        let channel = channels[slowIndex % channels.count]
        slowIndex += 1
        let command = String(format: "01%02X1", channel.pid)
        if await poll(command: command, continuation: continuation) == .noData {
            unsupported.insert(channel)
        }
    }

    // MARK: - Shared

    private func poll(
        command: String,
        continuation: AsyncStream<ObdSample>.Continuation
    ) async -> PollOutcome {
        do {
            let lines = try await session.execute(command)
            let timestamp = monotonicNow()
            for (pid, value) in PidDecoder.decodeMode01(lines: lines) {
                if let channel = ObdChannel(pid: pid) {
                    continuation.yield(ObdSample(channel: channel, value: value, timestamp: timestamp))
                }
            }
            return .ok
        } catch ElmError.noData {
            return .noData
        } catch ElmError.stopped {
            // Interrupted mid-command (expected around reconnects) — next cycle retries.
            return .transient
        } catch {
            // Transient failure (timeout, transport hiccup): brief pause, keep looping.
            try? await Task.sleep(for: .milliseconds(100))
            return .transient
        }
    }
}

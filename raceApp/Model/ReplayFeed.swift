//
//  ReplayFeed.swift
//  raceApp
//
//  Plays a recorded drive back through the telemetry bus as if the sensors
//  were live. Everything downstream — dashboard, gear tracker, held values,
//  calibration, lap timing, the recorder itself — cannot tell the difference,
//  so a real drive becomes a test fixture that runs on the desk.
//
//  Source is either a raw export (`LiveData-…-raw.json`, every channel at
//  native rate) or a session directory (channels/*.f64). Sample times are
//  shifted so the first sample is "now"; nothing is resampled.
//
//  DEBUG only: `simctl launch … -replay <path> [-replay-speed 2] [-replay-from 120] [-record]`.
//  It does not model the adapter or the radio: what was received is what
//  is replayed.
//

#if DEBUG
import Foundation
import SessionKit
import RaceBoxKit
import ObdKit

@MainActor @Observable
final class ReplayFeed {

    struct Sample: Sendable {
        let t: TimeInterval
        let channel: ChannelId
        let value: Double
    }

    private(set) var status = "idle" {
        didSet { print("[replay] \(status)") }
    }
    private(set) var progress: Double = 0
    private(set) var isRunning = false

    private let bus: TelemetryBus
    private var task: Task<Void, Never>?
    /// Called about once a second with the latest position/motion so the
    /// RaceBox controller can show a live link.
    var onRaceBoxFrame: ((RaceBoxDataMessage) -> Void)?

    init(bus: TelemetryBus) {
        self.bus = bus
    }

    // MARK: - Loading

    nonisolated static func load(path: String) throws -> [Sample] {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        var samples: [Sample] = []
        if isDir.boolValue {
            for channel in ChannelReader.channels(inSessionDirectory: url) {
                for s in ChannelReader.samples(for: channel, inSessionDirectory: url) {
                    samples.append(Sample(t: s.t, channel: channel, value: s.value))
                }
            }
        } else {
            struct Dump: Decodable {
                struct S: Decodable { let t: Double; let v: Double }
                let channels: [String: [S]]
            }
            let dump = try JSONDecoder().decode(Dump.self, from: Data(contentsOf: url))
            for (id, list) in dump.channels {
                let channel = ChannelId(id)
                for s in list { samples.append(Sample(t: s.t, channel: channel, value: s.v)) }
            }
        }
        samples.sort { $0.t < $1.t }
        return samples
    }

    // MARK: - Playback

    func start(path: String, speed: Double = 1, from offset: TimeInterval = 0) {
        stop()
        status = "loading"
        task = Task { [weak self] in
            guard let self else { return }
            let samples: [Sample]
            do {
                samples = try await Task.detached { try Self.load(path: path) }.value
            } catch {
                self.status = "failed: \(error.localizedDescription)"
                return
            }
            guard let first = samples.first?.t, let last = samples.last?.t else {
                self.status = "empty"
                return
            }
            let span = last - first
            let startIndex = samples.firstIndex { $0.t - first >= offset } ?? 0
            self.isRunning = true
            self.status = String(format: "%d samples · %.0f s · ×%.1f", samples.count, span, speed)

            let wallStart = monotonicNow()
            let replayStart = samples[startIndex].t
            var lastFrameT: TimeInterval = -1
            var frame = RaceBoxFrameState()
            var i = startIndex
            while i < samples.count, !Task.isCancelled {
                let due = wallStart + (samples[i].t - replayStart) / speed
                let now = monotonicNow()
                if due > now {
                    try? await Task.sleep(for: .milliseconds(max(1, Int((due - now) * 1000))))
                }
                let stamp = monotonicNow()
                // Publish everything due by now in one go (BLE delivers in bursts too).
                while i < samples.count, samples[i].t - replayStart <= (stamp - wallStart) * speed {
                    let s = samples[i]
                    self.publish(s, at: stamp)
                    frame.absorb(s)
                    i += 1
                }
                if stamp - lastFrameT >= 1, let message = frame.message() {
                    lastFrameT = stamp
                    self.onRaceBoxFrame?(message)
                }
                self.progress = span > 0 ? (samples[min(i, samples.count - 1)].t - first) / span : 1
            }
            self.isRunning = false
            self.status = Task.isCancelled ? "stopped" : "finished"
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// Recorded channels go on the bus as themselves; the live-only mirrors
    /// ConnectionController adds while streaming CAN are reproduced here so
    /// the dashboard sees exactly what it saw in the car.
    private func publish(_ s: Sample, at t: TimeInterval) {
        bus.publish(s.channel, s.value, at: t)
        switch s.channel {
        case .canRpm:
            bus.publishLive(.obd(.rpm), s.value, at: t)
        case .canAccelPedal:
            bus.publishLive(.obd(.acceleratorPedal), s.value, at: t)
            bus.publishLive(.obd(.throttle), s.value, at: t)
        default:
            break
        }
    }

    /// Enough of a RaceBox data message to light the links widget.
    private struct RaceBoxFrameState {
        var lat: Double?, lon: Double?, speed: Double?, alt: Double?
        var sats: Double?, fix: Double?
        var gx = 0.0, gy = 0.0, gz = 1.0
        var seen = false

        mutating func absorb(_ s: Sample) {
            switch s.channel {
            case .gpsLatitude: lat = s.value
            case .gpsLongitude: lon = s.value
            case .gpsSpeed: speed = s.value
            case .gpsAltitude: alt = s.value
            case .rbSatellites: sats = s.value; seen = true
            case .rbFixStatus: fix = s.value; seen = true
            case .rbGForceX: gx = s.value
            case .rbGForceY: gy = s.value
            case .rbGForceZ: gz = s.value
            default: break
            }
        }

        func message() -> RaceBoxDataMessage? {
            guard seen, let lat, let lon else { return nil }
            let sample = RaceBoxSample(latitude: lat, longitude: lon, altitudeMeters: alt ?? 0,
                                       speedMps: speed ?? 0,
                                       gForce: RaceBoxVector3(x: gx, y: gy, z: gz),
                                       satellites: Int(sats ?? 0), hasFix: (fix ?? 0) >= 3)
            let packet = RaceBoxEncoder.dataMessage(sample, model: .micro, powerByte: 121)
            return RaceBoxDataMessage(payload: packet.payload)
        }
    }
}
#endif

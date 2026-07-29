import Foundation

/// Signal discovery: given raw broadcast frames and simultaneous OBD "ground
/// truth" readings from the same capture, find which frame bytes encode which
/// truth channel. For every (frame ID, byte offset, u8/u16 width) it builds a
/// time series, pairs each truth sample with the nearest preceding frame, and
/// ranks linear fits `truth ≈ scale·raw + offset` by Pearson correlation.
///
/// This is how the "fake speed" on 0x202 was caught and how new channels
/// (coolant on 0x420, load/torque, oil temp…) get proposed for verification.
public enum CanCorrelator {

    public struct Candidate: Sendable, Equatable {
        public let frameID: UInt32
        public let byteOffset: Int
        public let width: Int          // 1 or 2 bytes, big-endian
        public let truthChannel: String
        public let correlation: Double
        public let scale: Double
        public let offset: Double
        public let pairCount: Int

        public var summary: String {
            String(format: "0x%03X %@[%d] ↔ %@  r=%+.3f  ≈ %.5g·raw %+.4g  (%d pairs)",
                   frameID, width == 2 ? "u16" : "u8", byteOffset, truthChannel,
                   correlation, scale, offset, pairCount)
        }
    }

    /// Strongest candidates first; at most two per (truth channel, frame ID)
    /// so a u16 match doesn't also flood the list with its two u8 halves.
    public static func match(frames: [CanFrame],
                             truth: [String: [(t: TimeInterval, value: Double)]],
                             minPairs: Int = 8,
                             minCorrelation: Double = 0.85,
                             maxPairGap: TimeInterval = 2.0) -> [Candidate] {
        var byID: [UInt32: [CanFrame]] = [:]
        for frame in frames where !(0x7E0...0x7EF).contains(frame.id) {
            byID[frame.id, default: []].append(frame)
        }

        var out: [Candidate] = []
        for (id, unsorted) in byID {
            let group = unsorted.sorted { $0.t < $1.t }
            guard group.count >= minPairs else { continue }
            let maxLen = group.map(\.data.count).max() ?? 0
            for width in [1, 2] where maxLen >= width {
                for offset in 0...(maxLen - width) {
                    var series: [(t: TimeInterval, value: Double)] = []
                    for frame in group where frame.data.count >= offset + width {
                        let raw: Double = width == 2
                            ? Double((UInt32(frame.data[offset]) << 8) | UInt32(frame.data[offset + 1]))
                            : Double(frame.data[offset])
                        series.append((frame.t, raw))
                    }
                    guard series.count >= minPairs, spread(series.map(\.value)) > 0 else { continue }

                    for (name, unsortedTruth) in truth {
                        let truthSamples = unsortedTruth.sorted { $0.t < $1.t }
                        guard truthSamples.count >= minPairs,
                              spread(truthSamples.map(\.value)) > 0.001 else { continue }
                        var xs: [Double] = []
                        var ys: [Double] = []
                        var cursor = 0
                        for sample in truthSamples {
                            while cursor + 1 < series.count, series[cursor + 1].t <= sample.t {
                                cursor += 1
                            }
                            guard abs(series[cursor].t - sample.t) <= maxPairGap else { continue }
                            xs.append(series[cursor].value)
                            ys.append(sample.value)
                        }
                        guard xs.count >= minPairs, spread(xs) > 0,
                              let r = pearson(xs, ys), abs(r) >= minCorrelation,
                              let fit = linearFit(x: xs, y: ys) else { continue }
                        out.append(Candidate(frameID: id, byteOffset: offset, width: width,
                                             truthChannel: name, correlation: r,
                                             scale: fit.a, offset: fit.b, pairCount: xs.count))
                    }
                }
            }
        }

        out.sort { abs($0.correlation) > abs($1.correlation) }
        var kept: [Candidate] = []
        var perKey: [String: Int] = [:]
        for candidate in out {
            let key = "\(candidate.truthChannel)|\(candidate.frameID)"
            if perKey[key, default: 0] < 2 {
                kept.append(candidate)
                perKey[key, default: 0] += 1
            }
        }
        return kept
    }

    // MARK: - Math

    private static func spread(_ values: [Double]) -> Double {
        guard let lo = values.min(), let hi = values.max() else { return 0 }
        return hi - lo
    }

    private static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        let n = Double(x.count)
        guard n > 1 else { return nil }
        let mx = x.reduce(0, +) / n
        let my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<x.count {
            let dx = x[i] - mx
            let dy = y[i] - my
            sxy += dx * dy
            sxx += dx * dx
            syy += dy * dy
        }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    /// Least-squares fit y = a·x + b.
    private static func linearFit(x: [Double], y: [Double]) -> (a: Double, b: Double)? {
        let n = Double(x.count)
        guard n > 1 else { return nil }
        let mx = x.reduce(0, +) / n
        let my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for i in 0..<x.count {
            sxy += (x[i] - mx) * (y[i] - my)
            sxx += (x[i] - mx) * (x[i] - mx)
        }
        guard sxx > 0 else { return nil }
        let a = sxy / sxx
        return (a, my - a * mx)
    }
}

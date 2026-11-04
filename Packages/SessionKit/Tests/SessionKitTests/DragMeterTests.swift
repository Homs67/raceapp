import Testing
import Foundation
@testable import SessionKit

struct DragMeterTests {

    /// Feed a constant-acceleration ramp and check 0–60 mph matches v=at.
    @Test func zeroToSixtyMatchesConstantAccel() {
        let a = 4.0                       // m/s² (~0–60 in 6.7 s)
        let meter = DragMeter()
        let dt = 0.05
        meter.add(speedMps: 0, t: 0)      // standstill
        var t = dt
        while t < 20 {
            meter.add(speedMps: a * t, t: t)
            t += dt
        }
        // Measured from launch (v≈1 m/s rollout), per drag convention.
        let expected = (26.8224 - 1.0) / a    // ~6.46 s
        #expect(meter.current.zeroToSixty != nil)
        #expect(abs((meter.current.zeroToSixty ?? 0) - expected) < 0.2)
    }

    @Test func quarterMileRecordsTimeAndTrap() {
        let a = 4.0
        let meter = DragMeter()
        meter.add(speedMps: 0, t: 0)
        var t = 0.05
        while t < 30 {
            meter.add(speedMps: a * t, t: t)
            t += 0.05
        }
        // ¼ mile (402.34 m) under constant accel: d=½at² → t=√(2d/a) ≈ 14.18 s
        let expected = (2 * 402.336 / a).squareRoot()
        #expect(meter.current.quarterMile != nil)
        #expect(abs((meter.current.quarterMile ?? 0) - expected) < 0.4)
        #expect((meter.current.quarterMileTrapKmh ?? 0) > 150)   // fast trap
    }

    /// A pull to 50 mph, a lift into a corner, then 110 mph down the next straight:
    /// the lift ends the run, so 0–100 is never timed from the old launch.
    @Test func liftEndsTheRun() {
        let meter = DragMeter()
        meter.add(speedMps: 0, t: 0)
        var t = 0.05, v = 0.0
        while v < 22 { v += 4 * 0.05; meter.add(speedMps: v, t: t); t += 0.05 }
        while v > 15 { v -= 6 * 0.05; meter.add(speedMps: v, t: t); t += 0.05 }
        while v < 49 { v += 3 * 0.05; meter.add(speedMps: v, t: t); t += 0.05 }
        #expect(meter.best.zeroToHundred == nil)
        #expect(meter.best.zeroToSixty == nil)
        #expect(!meter.current.launching)
    }

    @Test func doesNotTriggerWithoutStandstillLaunch() {
        // Already moving fast the whole time — no launch from rest.
        let meter = DragMeter()
        var t = 0.0
        while t < 10 { meter.add(speedMps: 30, t: t); t += 0.1 }
        #expect(meter.current.zeroToSixty == nil)
        #expect(meter.current.launching == false)
    }

    /// A recording that ends mid-pull still counts its splits once finished.
    @Test func finishMergesRunInProgress() {
        let a = 4.0
        let meter = DragMeter()
        meter.add(speedMps: 0, t: 0)
        var t = 0.05
        while t < 12 { meter.add(speedMps: a * t, t: t); t += 0.05 }   // tops out at 48 m/s
        #expect(meter.best.zeroTo100Kmh == nil)
        meter.finish()
        let expected = (27.7778 - 1.0) / a
        #expect(abs((meter.best.zeroTo100Kmh ?? 0) - expected) < 0.2)
        #expect(meter.best.zeroToSixty != nil)
        #expect(meter.best.zeroTo200Kmh == nil)       // 55.6 m/s not reached
        #expect(meter.current.launching == false)
    }
}

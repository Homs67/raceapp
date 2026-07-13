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

    @Test func doesNotTriggerWithoutStandstillLaunch() {
        // Already moving fast the whole time — no launch from rest.
        let meter = DragMeter()
        var t = 0.0
        while t < 10 { meter.add(speedMps: 30, t: t); t += 0.1 }
        #expect(meter.current.zeroToSixty == nil)
        #expect(meter.current.launching == false)
    }
}

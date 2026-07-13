import XCTest
@testable import SessionKit

final class GForceValidatorTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gval-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// v(t) = 20 + 10·sin(t/5) m/s → a(t) = 2·cos(t/5) m/s².
    /// Writes GPS speed at 1 Hz and car.longG at 20 Hz scaled by `gScale`.
    private func writeSyntheticDrive(gScale: Double, seconds: Int = 240) async throws {
        let writer = try SessionWriter(sessionDirectory: directory)
        for second in 0..<seconds {
            let t = Double(second)
            await writer.append(.gpsSpeed, value: 20 + 10 * sin(t / 5), at: 100 + t)
            for sub in 0..<20 {
                let ts = t + Double(sub) / 20
                let accelG = 2 * cos(ts / 5) / 9.81
                // Small deterministic "road noise"
                let noise = 0.01 * sin(ts * 13)
                await writer.append(.carLongG, value: accelG * gScale + noise, at: 100 + ts)
                await writer.append(.carLatG, value: 0.2 * sin(ts / 7), at: 100 + ts)
                await writer.append(.imuYawRate, value: 0.05 * sin(ts / 7), at: 100 + ts)
            }
        }
        _ = await writer.close()
    }

    func testCorrectCalibrationVerifies() async throws {
        try await writeSyntheticDrive(gScale: 1.0)
        let result = GForceValidation.validate(sessionDirectory: directory)
        XCTAssertEqual(result.verdict, .verified)
        XCTAssertGreaterThan(result.longCorrelation ?? 0, 0.9)
        XCTAssertEqual(result.longScale ?? 0, 1.0, accuracy: 0.1)
        XCTAssertGreaterThan(result.pairCount, 100)
    }

    func testMisScaledCalibrationFails() async throws {
        // e.g. wrong axis picked up only a component — G reads 3× too large
        try await writeSyntheticDrive(gScale: 3.0)
        let result = GForceValidation.validate(sessionDirectory: directory)
        XCTAssertNotEqual(result.verdict, .verified, "scale 3.0 must not verify")
    }

    func testUncorrelatedDataFails() async throws {
        let writer = try SessionWriter(sessionDirectory: directory)
        for second in 0..<240 {
            let t = Double(second)
            await writer.append(.gpsSpeed, value: 20 + 10 * sin(t / 5), at: 100 + t)
            for sub in 0..<20 {
                let ts = t + Double(sub) / 20
                // G bears no relation to the speed profile
                await writer.append(.carLongG, value: 0.3 * sin(ts * 1.7), at: 100 + ts)
            }
        }
        _ = await writer.close()
        let result = GForceValidation.validate(sessionDirectory: directory)
        XCTAssertEqual(result.verdict, .failed)
    }

    func testNoCalibratedChannelsReported() async throws {
        let writer = try SessionWriter(sessionDirectory: directory)
        for second in 0..<60 {
            await writer.append(.gpsSpeed, value: 15, at: 100 + Double(second))
            await writer.append(.imuAccelY, value: 0.1, at: 100 + Double(second))
        }
        _ = await writer.close()
        let result = GForceValidation.validate(sessionDirectory: directory)
        XCTAssertEqual(result.verdict, .noCalibratedData)
    }

    func testConstantSpeedIsInsufficient() async throws {
        // Highway cruise: nothing to correlate against
        let writer = try SessionWriter(sessionDirectory: directory)
        for second in 0..<240 {
            let t = Double(second)
            await writer.append(.gpsSpeed, value: 30, at: 100 + t)
            for sub in 0..<20 {
                await writer.append(.carLongG, value: 0.005, at: 100 + t + Double(sub) / 20)
            }
        }
        _ = await writer.close()
        let result = GForceValidation.validate(sessionDirectory: directory)
        XCTAssertEqual(result.verdict, .insufficientData)
    }
}

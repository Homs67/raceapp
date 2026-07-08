#if os(iOS)
import CoreLocation
import CoreMotion
import UIKit
import ObdKit

/// Phone-side capture (04 §1): GPS with per-fix accuracy, 100Hz device motion,
/// barometer, and device health. Emits into the same (channel, value, t)
/// pipeline as OBD samples. Behavior is validated on-device — this type stays
/// deliberately thin so everything downstream of the callback is testable.
public final class PhoneSensorSuite: NSObject, @unchecked Sendable {

    public typealias SampleHandler = @Sendable (_ channel: ChannelId, _ value: Double, _ t: TimeInterval) -> Void

    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let motionQueue = OperationQueue()
    private var healthTimer: Timer?
    private var handler: SampleHandler?

    public override init() {
        super.init()
        motionQueue.maxConcurrentOperationCount = 1
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    public func requestPermissions() {
        // "Always" so recording survives a screen lock / backgrounding for a full
        // drive. iOS shows the When-In-Use prompt first, then a later upgrade
        // prompt to Always once background use is observed.
        locationManager.requestAlwaysAuthorization()
    }

    public func start(handler: @escaping SampleHandler) {
        self.handler = handler

        // Escalate to Always if the user previously chose When-In-Use.
        if locationManager.authorizationStatus == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        }

        // GPS — background-capable (location background mode + Always auth)
        if CLLocationManager.locationServicesEnabled() {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.startUpdatingLocation()
        }

        // Device motion @ 100Hz: gravity-separated user acceleration (g),
        // rotation rates, heading
        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 1.0 / 100.0
            motionManager.startDeviceMotionUpdates(
                using: .xMagneticNorthZVertical, to: motionQueue
            ) { [weak self] motion, _ in
                guard let self, let motion, let emit = self.handler else { return }
                let t = motion.timestamp // already monotonic uptime
                emit(.imuAccelX, motion.userAcceleration.x, t)
                emit(.imuAccelY, motion.userAcceleration.y, t)
                emit(.imuAccelZ, motion.userAcceleration.z, t)
                emit(.imuYawRate, motion.rotationRate.z, t)
                emit(.imuPitchRate, motion.rotationRate.x, t)
                emit(.imuRollRate, motion.rotationRate.y, t)
                if motion.heading >= 0 { emit(.imuHeading, motion.heading, t) }
            }
        }

        // Barometer — relative elevation
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: motionQueue) { [weak self] data, _ in
                guard let self, let data, let emit = self.handler else { return }
                emit(.baroRelativeAltitude, data.relativeAltitude.doubleValue, monotonicNow())
            }
        }

        // Device health @ 0.2Hz
        UIDevice.current.isBatteryMonitoringEnabled = true
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let emit = self?.handler else { return }
            let t = monotonicNow()
            let battery = Double(UIDevice.current.batteryLevel)
            if battery >= 0 { emit(.deviceBattery, battery, t) }
            emit(.deviceThermalState, Double(ProcessInfo.processInfo.thermalState.rawValue), t)
        }
    }

    public func stop() {
        locationManager.stopUpdatingLocation()
        motionManager.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        healthTimer?.invalidate()
        healthTimer = nil
        handler = nil
    }
}

extension PhoneSensorSuite: CLLocationManagerDelegate {

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let emit = handler else { return }
        for location in locations {
            // CLLocation timestamps are wall-clock; map to the monotonic session
            // clock via the current offset (sub-100ms error, fine at 1Hz GPS).
            let t = monotonicNow() - Date().timeIntervalSince(location.timestamp)
            emit(.gpsLatitude, location.coordinate.latitude, t)
            emit(.gpsLongitude, location.coordinate.longitude, t)
            emit(.gpsAltitude, location.altitude, t)
            emit(.gpsHorizontalAccuracy, location.horizontalAccuracy, t)
            if location.speed >= 0 { emit(.gpsSpeed, location.speed, t) }
            if location.course >= 0 { emit(.gpsCourse, location.course, t) }
        }
    }
}
#endif

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
    public enum BackgroundLocationStatus: Equatable, Sendable {
        case servicesDisabled
        case notDetermined
        case whenInUse
        case always
        case denied

        public var supportsLockedRecording: Bool { self == .always }
    }

    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let motionQueue = OperationQueue()
    private let healthQueue = DispatchQueue(label: "sessionkit.device-health")
    private let stateLock = NSLock()
    private var healthTimer: DispatchSourceTimer?
    private var backgroundActivitySession: CLBackgroundActivitySession?
    private var handler: SampleHandler?
    private var recordingActive = false
    private var backgrounded = false
    public var onBackgroundLocationStatusChange:
        (@MainActor @Sendable (BackgroundLocationStatus) -> Void)?

    // Auto G-calibration state (guarded by calibrationLock: the location
    // delegate and the 100Hz motion handler run on different queues).
    private let calibrationLock = NSLock()
    private var calibrator = CarFrameCalibrator()
    private var smoothedLatG: Double?
    private var smoothedLongG: Double?
    /// Last time an external logger reported a fix. While that is recent the
    /// logger owns `gps.*` and the car-frame alignment; the phone's own fixes
    /// become the `phone.*` cross-check. Time-based rather than a flag so a
    /// logger that drops out mid-drive hands position back on its own.
    private var lastExternalFixT: TimeInterval?
    /// Separately tracked: a logger can have a position solution but no
    /// heading one (the ND2 drive never set RaceBox `headingValid`), and
    /// course is an independent quantity — leaving it unpublished would blind
    /// the G-force validator and the heading readout.
    private var lastExternalCourseT: TimeInterval?
    /// Set while a logger is publishing car-frame G of its own. Its
    /// accelerometer is bolted to the car where the phone's rides in a
    /// cradle, so when both are available the logger wins.
    private var lastExternalCarFrameT: TimeInterval?

    /// How long a logger's silence is tolerated before the phone takes over.
    /// Matches the recorder's motion-source rule.
    private static let externalSourceGrace: TimeInterval = 3

    private var externalOwnsPosition: Bool {
        guard let last = lastExternalFixT else { return false }
        return monotonicNow() - last < Self.externalSourceGrace
    }

    private var externalOwnsCourse: Bool {
        guard let last = lastExternalCourseT else { return false }
        return monotonicNow() - last < Self.externalSourceGrace
    }

    private var externalOwnsCarFrame: Bool {
        guard let last = lastExternalCarFrameT else { return false }
        return monotonicNow() - last < Self.externalSourceGrace
    }

    /// A logger reported car-frame G: stand down until it stops. Separate from
    /// position ownership because the logger's alignment converges later than
    /// its first fix, and the phone should keep driving the gauge until then.
    public func noteExternalCarFrame(at t: TimeInterval) {
        calibrationLock.lock()
        lastExternalCarFrameT = monotonicNow()
        calibrationLock.unlock()
    }

    /// Speed from an external logger (RaceBox, 25 Hz). Drives the car-frame
    /// alignment in place of the phone's 1 Hz CoreLocation estimate, and marks
    /// the logger as the owner of `gps.*`.
    ///
    /// The alignment solves for the car's forward axis by correlating IMU
    /// acceleration against the derivative of ground speed, so its accuracy is
    /// capped by the speed source: phone speed (±0.2–4 m/s, 1 Hz, smoothed) was
    /// good for ~50° of misalignment on a real drive.
    public func ingestExternalFix(speed mps: Double, course: Double?, at t: TimeInterval) {
        calibrationLock.lock()
        let now = monotonicNow()
        lastExternalFixT = now
        if course != nil { lastExternalCourseT = now }
        calibrator.ingestSpeed(mps, at: t)
        calibrationLock.unlock()
    }

    /// Restart calibration (called at each session start — mounts move between drives).
    public func recalibrate() {
        calibrationLock.lock()
        calibrator.reset()
        smoothedLatG = nil
        smoothedLongG = nil
        lastExternalFixT = nil
        lastExternalCourseT = nil
        lastExternalCarFrameT = nil
        calibrationLock.unlock()
    }

    public override init() {
        super.init()
        motionQueue.maxConcurrentOperationCount = 1
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.activityType = .automotiveNavigation
        locationManager.showsBackgroundLocationIndicator = true
    }

    public var backgroundLocationStatus: BackgroundLocationStatus {
        guard CLLocationManager.locationServicesEnabled() else { return .servicesDisabled }
        return switch locationManager.authorizationStatus {
        case .authorizedAlways: .always
        case .authorizedWhenInUse: .whenInUse
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    public func requestPermissions() {
        // "Always" so recording survives a screen lock / backgrounding for a full
        // drive. iOS shows the When-In-Use prompt first, then a later upgrade
        // prompt to Always once background use is observed.
        switch locationManager.authorizationStatus {
        case .notDetermined, .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
        publishBackgroundLocationStatus()
    }

    public func refreshAuthorizationStatus() {
        publishBackgroundLocationStatus()
    }

    /// Marks an active drive for Core Location. This is not a generic
    /// keep-alive: it tells iOS that background location updates are
    /// user-initiated and should continue while the screen is locked.
    public func beginRecordingActivity() {
        stateLock.lock()
        recordingActive = true
        stateLock.unlock()
        if locationManager.authorizationStatus == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        }
        ensureBackgroundActivitySession()
        configureLocationUpdates(forceRestart: true)
        applyMotionUpdateRate()
    }

    public func endRecordingActivity() {
        stateLock.lock()
        recordingActive = false
        backgrounded = false
        stateLock.unlock()
        backgroundActivitySession?.invalidate()
        backgroundActivitySession = nil
        applyMotionUpdateRate()
    }

    /// Called when the scene enters background during an active session.
    /// Re-asserts the GPS keep-alive and drops IMU rate to reduce thermal
    /// pressure (a common reason iOS suspends locked drives).
    public func enterBackgroundRecordingMode() {
        stateLock.lock()
        backgrounded = true
        let active = recordingActive
        stateLock.unlock()
        guard active else { return }
        ensureBackgroundActivitySession()
        configureLocationUpdates(forceRestart: true)
        applyMotionUpdateRate()
    }

    /// Restore full-rate motion capture when the app is foregrounded again.
    public func enterForegroundRecordingMode() {
        stateLock.lock()
        backgrounded = false
        let active = recordingActive
        stateLock.unlock()
        applyMotionUpdateRate()
        if active {
            configureLocationUpdates(forceRestart: false)
        }
        publishBackgroundLocationStatus()
    }

    public func start(handler: @escaping SampleHandler) {
        self.handler = handler

        // Escalate to Always if the user previously chose When-In-Use.
        if locationManager.authorizationStatus == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        }

        // GPS — background-capable (location background mode + Always auth).
        configureLocationUpdates(forceRestart: false)

        // Device motion: 100Hz in foreground, reduced while locked/recording.
        startMotionUpdates()

        // Barometer — relative elevation
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: motionQueue) { [weak self] data, _ in
                guard let self, let data, let emit = self.handler else { return }
                emit(.baroRelativeAltitude, data.relativeAltitude.doubleValue, monotonicNow())
            }
        }

        // Device health @ 0.2Hz
        UIDevice.current.isBatteryMonitoringEnabled = true
        let timer = DispatchSource.makeTimerSource(queue: healthQueue)
        timer.schedule(deadline: .now(), repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let emit = self?.handler else { return }
            let t = monotonicNow()
            let battery = Double(UIDevice.current.batteryLevel)
            if battery >= 0 { emit(.deviceBattery, battery, t) }
            emit(.deviceThermalState, Double(ProcessInfo.processInfo.thermalState.rawValue), t)
        }
        healthTimer = timer
        timer.resume()
    }

    public func stop() {
        endRecordingActivity()
        locationManager.stopUpdatingLocation()
        motionManager.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        healthTimer?.cancel()
        healthTimer = nil
        handler = nil
    }

    private func ensureBackgroundActivitySession() {
        if backgroundActivitySession == nil {
            backgroundActivitySession = CLBackgroundActivitySession()
        }
    }

    private func configureLocationUpdates(forceRestart: Bool) {
        guard CLLocationManager.locationServicesEnabled() else {
            publishBackgroundLocationStatus()
            return
        }
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            // Always is required for reliable lock-screen capture; When-In-Use
            // still gets background updates while the activity session is alive.
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = true
            locationManager.pausesLocationUpdatesAutomatically = false
            if forceRestart {
                locationManager.stopUpdatingLocation()
            }
            locationManager.startUpdatingLocation()
        case .notDetermined, .denied, .restricted:
            break
        @unknown default:
            break
        }
        publishBackgroundLocationStatus()
    }

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        applyMotionUpdateRate()
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

            // Car-frame G, once the auto-calibration has leveled + aligned.
            let gravity = Vector3(motion.gravity.x, motion.gravity.y, motion.gravity.z)
            let accel = Vector3(motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z)
            self.calibrationLock.lock()
            self.calibrator.ingestMotion(
                gravity: gravity, userAccel: accel,
                rotationRate: Vector3(motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z))
            if self.externalOwnsCarFrame {
                self.calibrationLock.unlock()
            } else if let g = self.calibrator.carFrame(userAccel: accel) {
                // Light EMA (~4 Hz at 100 Hz sampling): keeps the gauge readable
                // without hiding real transients. Raw imu.* stay unfiltered.
                let alpha = 0.2
                let lat = (self.smoothedLatG ?? g.latG) * (1 - alpha) + g.latG * alpha
                let long = (self.smoothedLongG ?? g.longG) * (1 - alpha) + g.longG * alpha
                self.smoothedLatG = lat
                self.smoothedLongG = long
                self.calibrationLock.unlock()
                emit(.carLatG, lat, t)
                emit(.carLongG, long, t)
            } else {
                self.calibrationLock.unlock()
            }
        }
    }

    private func applyMotionUpdateRate() {
        guard motionManager.isDeviceMotionAvailable else { return }
        stateLock.lock()
        let reduced = recordingActive && backgrounded
        stateLock.unlock()
        // 20 Hz while locked keeps car-frame G usable and cuts CoreMotion work
        // that contributes to thermal suspension on long drives.
        motionManager.deviceMotionUpdateInterval = reduced ? 1.0 / 20.0 : 1.0 / 100.0
    }

    private func publishBackgroundLocationStatus() {
        guard let callback = onBackgroundLocationStatusChange else { return }
        let status = backgroundLocationStatus
        Task { @MainActor in callback(status) }
    }
}

extension PhoneSensorSuite: CLLocationManagerDelegate {

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        configureLocationUpdates(forceRestart: false)
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let emit = handler else { return }
        for location in locations {
            // CLLocation timestamps are wall-clock; map to the monotonic session
            // clock via the current offset (sub-100ms error, fine at 1Hz GPS).
            let t = monotonicNow() - Date().timeIntervalSince(location.timestamp)

            // A connected logger owns gps.*: mixing the phone's 1 Hz ±10 m
            // fixes into a 25 Hz ±0.3 m stream poisons every consumer that
            // reads the latest value. Keep them as an independent cross-check.
            calibrationLock.lock()
            let external = externalOwnsPosition
            let externalCourse = externalOwnsCourse
            calibrationLock.unlock()
            guard !external else {
                emit(.phoneLatitude, location.coordinate.latitude, t)
                emit(.phoneLongitude, location.coordinate.longitude, t)
                if location.speed >= 0 { emit(.phoneSpeed, location.speed, t) }
                // Course is not position: when the logger has no heading
                // solution the phone's is the only one there is.
                if location.course >= 0, !externalCourse {
                    emit(.gpsCourse, location.course, t)
                }
                continue
            }

            emit(.gpsLatitude, location.coordinate.latitude, t)
            emit(.gpsLongitude, location.coordinate.longitude, t)
            emit(.gpsAltitude, location.altitude, t)
            emit(.gpsHorizontalAccuracy, location.horizontalAccuracy, t)
            if location.verticalAccuracy >= 0 {
                emit(.gpsVerticalAccuracy, location.verticalAccuracy, t)
            }
            if location.speedAccuracy >= 0 {
                emit(.gpsSpeedAccuracy, location.speedAccuracy, t)
            }
            emit(.gpsWallTime, location.timestamp.timeIntervalSince1970, t)
            if location.speed >= 0 {
                emit(.gpsSpeed, location.speed, t)
                calibrationLock.lock()
                calibrator.ingestSpeed(location.speed, at: t)
                calibrationLock.unlock()
            }
            if location.course >= 0 { emit(.gpsCourse, location.course, t) }
        }
    }
}
#endif

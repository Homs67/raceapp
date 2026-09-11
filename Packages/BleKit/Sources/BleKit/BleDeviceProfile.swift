import Foundation

/// How to find and talk to one class of BLE serial device.
///
/// One `CoreBluetoothTransport` (and therefore one `CBCentralManager`) per
/// profile, so the app can hold an OBD adapter and a RaceBox open at the same
/// time. **Restore identifiers must be unique per profile** — two managers
/// sharing one identifier corrupts CoreBluetooth state until app relaunch.
public struct BleDeviceProfile: Sendable, Equatable {

    /// CoreBluetooth state-restoration key. Unique per profile; nil opts out.
    public let restoreIdentifier: String?
    /// Advertised-name filter for scanning (case-insensitive `contains`).
    public let advertisedName: String?
    /// Candidate serial services, best first — also used to find peripherals
    /// that are already connected to the system.
    public let serviceUUIDs: [String]
    /// Candidate write characteristics, best first.
    public let writeUUIDs: [String]
    /// Candidate notify characteristics, best first.
    public let notifyUUIDs: [String]
    /// When no candidate matches, adopt the first writable/notifiable pair
    /// found anywhere in the GATT tree. True for adapters whose vendor UART
    /// varies by clone; false for devices with a documented, fixed service.
    public let allowsHeuristicFallback: Bool

    public init(restoreIdentifier: String?, advertisedName: String?,
                serviceUUIDs: [String], writeUUIDs: [String], notifyUUIDs: [String],
                allowsHeuristicFallback: Bool) {
        self.restoreIdentifier = restoreIdentifier
        self.advertisedName = advertisedName
        self.serviceUUIDs = serviceUUIDs
        self.writeUUIDs = writeUUIDs
        self.notifyUUIDs = notifyUUIDs
        self.allowsHeuristicFallback = allowsHeuristicFallback
    }

    /// ELM327 OBD-II adapters. Veepeak-class devices expose a vendor UART —
    /// commonly FFF0 (FFF1 notify / FFF2 write) or FFE0/FFE1 — but clones vary,
    /// so unknown trees fall back to the first serial-looking pair.
    public static let elm327 = BleDeviceProfile(
        restoreIdentifier: "com.raceapp.obd-central",
        advertisedName: "VEEPEAK",
        serviceUUIDs: ["FFF0", "FFE0"],
        writeUUIDs: ["FFF2", "FFE1"],
        notifyUUIDs: ["FFF1", "FFE1"],
        allowsHeuristicFallback: true
    )

    /// RaceBox Mini / Mini S / Micro — Nordic UART, documented and fixed
    /// (BLE Protocol doc rev 9). No fallback: anything else is not a RaceBox.
    public static let raceBox = BleDeviceProfile(
        restoreIdentifier: "com.raceapp.racebox-central",
        advertisedName: "RaceBox",
        serviceUUIDs: ["6E400001-B5A3-F393-E0A9-E50E24DCCA9E"],
        writeUUIDs: ["6E400002-B5A3-F393-E0A9-E50E24DCCA9E"],
        notifyUUIDs: ["6E400003-B5A3-F393-E0A9-E50E24DCCA9E"],
        allowsHeuristicFallback: false
    )
}

/// Standard Device Information service (0x180A) characteristics, read after
/// connecting to identify hardware.
public enum DeviceInfoCharacteristic: String, CaseIterable, Sendable {
    case model = "2A24"
    case serialNumber = "2A25"
    case firmwareRevision = "2A26"
    case hardwareRevision = "2A27"
    case manufacturer = "2A29"

    public static let serviceUUID = "180A"
}

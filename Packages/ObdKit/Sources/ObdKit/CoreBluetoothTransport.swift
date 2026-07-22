#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
import Foundation

public struct DiscoveredAdapter: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let rssi: Int

    public init(id: UUID, name: String, rssi: Int) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}

public enum BleTransportError: Error {
    case bluetoothUnavailable
    case bluetoothUnauthorized
    case peripheralNotFound
    case connectionFailed(String)
    case noSerialCharacteristics
}

/// Coarse Bluetooth radio / permission state for UI (Settings OBD card).
public enum BluetoothRadioState: Equatable, Sendable {
    case unknown
    case poweredOff
    case unauthorized
    case unsupported
    case poweredOn
}

/// Real-adapter transport over CoreBluetooth. Veepeak-class adapters expose a
/// vendor UART service — commonly FFF0 (FFF1 notify / FFF2 write) or FFE0/FFE1.
/// We try the known candidates first, then fall back to the first
/// (notify, write) characteristic pair found anywhere in the GATT tree.
/// The full tree is logged for the driveway spike (03 §6).
///
/// Important: only one instance should own the restore identifier. The app
/// reuses a single transport for scan + connect so CoreBluetooth state stays
/// coherent.
public final class CoreBluetoothTransport: NSObject, ObdTransport, @unchecked Sendable {

    public static let advertisedName = "VEEPEAK"
    public static let restorationIdentifier = "com.raceapp.obd-central"

    private static let knownServiceUuids: [CBUUID] = [
        CBUUID(string: "FFF0"), CBUUID(string: "FFE0"),
    ]
    private static let knownWriteUuids: [CBUUID] = [CBUUID(string: "FFF2"), CBUUID(string: "FFE1")]
    private static let knownNotifyUuids: [CBUUID] = [CBUUID(string: "FFF1"), CBUUID(string: "FFE1")]

    public let incoming: AsyncStream<Data>
    private let incomingContinuation: AsyncStream<Data>.Continuation

    private let queue = DispatchQueue(label: "obdkit.ble")
    private lazy var central = CBCentralManager(
        delegate: self,
        queue: queue,
        options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier]
    )
    private let lock = NSLock()

    private var peripheral: CBPeripheral?
    private var knownPeripherals: [UUID: CBPeripheral] = [:]
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    private var poweredOnContinuations: [CheckedContinuation<Void, Error>] = []
    private var scanContinuation: AsyncStream<DiscoveredAdapter>.Continuation?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var pendingServiceCount = 0
    private var intentionalDisconnect = false

    /// Full GATT tree of the last connected peripheral, for spike logging.
    public private(set) var gattTreeDescription = ""
    /// Called on unexpected disconnect after a successful link; the connection
    /// controller drives reconnects. Not fired for mid-connect failures (those
    /// resume the connect continuation so the retry loop can back off).
    public var onDisconnect: (() -> Void)?
    /// Called when iOS relaunches the app to restore a connected peripheral.
    public var onRestore: ((UUID) -> Void)?
    /// Fired on the CoreBluetooth queue whenever central state changes.
    public var onRadioStateChange: ((BluetoothRadioState) -> Void)?

    public private(set) var radioState: BluetoothRadioState = .unknown

    public override init() {
        var continuation: AsyncStream<Data>.Continuation!
        self.incoming = AsyncStream { continuation = $0 }
        self.incomingContinuation = continuation
        super.init()
        // Creating the manager at launch opts into CoreBluetooth restoration;
        // leaving this lazy until the first user action would miss the callback.
        _ = central
    }

    // MARK: - Scanning

    /// Scan for adapters. `nameFilter: nil` lists everything (the
    /// "Don't see your adapter?" expander); default filters to VEEPEAK.
    public func scan(nameFilter: String? = CoreBluetoothTransport.advertisedName) async throws -> AsyncStream<DiscoveredAdapter> {
        try await waitForPoweredOn()
        return AsyncStream { continuation in
            lock.lock()
            scanContinuation = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.queue.async { self?.central.stopScan() }
            }
            queue.async { [self] in
                scanNameFilter = nameFilter
                central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
        }
    }
    private var scanNameFilter: String?

    public func stopScan() {
        queue.async { [self] in
            central.stopScan()
            lock.lock()
            scanContinuation = nil
            lock.unlock()
        }
    }

    // MARK: - Connecting

    /// Connect to a previously discovered or persisted peripheral, discover its
    /// serial characteristics, and subscribe. Ready to `send` on return.
    public func connect(to id: UUID) async throws {
        try await waitForPoweredOn()
        guard let target = resolvePeripheral(id: id) else {
            throw BleTransportError.peripheralNotFound
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            // A second connect() must not orphan the previous waiter.
            let previous = connectContinuation
            connectContinuation = continuation
            peripheral = target
            intentionalDisconnect = false
            lock.unlock()
            previous?.resume(throwing: BleTransportError.connectionFailed("superseded"))
            queue.async { [self] in
                target.delegate = self
                if target.state == .connected {
                    // A state-restored peripheral is already linked; rebuild
                    // GATT subscriptions before the ELM handshake resumes.
                    target.discoverServices(nil)
                } else {
                    central.connect(target, options: nil)
                }
            }
        }
    }

    public func disconnect() {
        queue.async { [self] in
            lock.lock()
            intentionalDisconnect = true
            lock.unlock()
            central.stopScan()
            if let peripheral { central.cancelPeripheralConnection(peripheral) }
        }
    }

    // MARK: - Sending

    public func send(_ data: Data) async throws {
        guard let peripheral, let characteristic = writeCharacteristic else {
            throw ObdTransportError.notConnected
        }
        let withoutResponse = characteristic.properties.contains(.writeWithoutResponse)
        let type: CBCharacteristicWriteType = withoutResponse ? .withoutResponse : .withResponse
        let maxLength = peripheral.maximumWriteValueLength(for: type)
        var offset = 0
        while offset < data.count {
            let chunk = data.subdata(in: offset..<min(offset + maxLength, data.count))
            peripheral.writeValue(chunk, for: characteristic, type: type)
            offset += maxLength
        }
    }

    // MARK: - Power state

    private func resolvePeripheral(id: UUID) -> CBPeripheral? {
        lock.lock()
        let cached = knownPeripherals[id]
        lock.unlock()
        if let cached { return cached }
        if let retrieved = central.retrievePeripherals(withIdentifiers: [id]).first {
            lock.lock()
            knownPeripherals[id] = retrieved
            lock.unlock()
            return retrieved
        }
        let connected = central.retrieveConnectedPeripherals(withServices: Self.knownServiceUuids)
            .first { $0.identifier == id }
        if let connected {
            lock.lock()
            knownPeripherals[id] = connected
            lock.unlock()
        }
        return connected
    }

    private func waitForPoweredOn() async throws {
        switch central.state {
        case .poweredOn: return
        case .unauthorized: throw BleTransportError.bluetoothUnauthorized
        case .unsupported: throw BleTransportError.bluetoothUnavailable
        default: break
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            poweredOnContinuations.append(continuation)
            lock.unlock()
        }
    }

    private func resolvePoweredOnWaiters(_ result: Result<Void, Error>) {
        lock.lock()
        let waiters = poweredOnContinuations
        poweredOnContinuations = []
        lock.unlock()
        for waiter in waiters { waiter.resume(with: result) }
    }

    private func finishConnect(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = connectContinuation
        connectContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

// MARK: - CBCentralManagerDelegate

extension CoreBluetoothTransport: CBCentralManagerDelegate {

    public func centralManager(_ central: CBCentralManager,
                               willRestoreState dict: [String: Any]) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey]
                              as? [CBPeripheral])?.first else { return }
        lock.lock()
        peripheral = restored
        knownPeripherals[restored.identifier] = restored
        lock.unlock()
        restored.delegate = self
        onRestore?(restored.identifier)
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let mapped: BluetoothRadioState
        switch central.state {
        case .poweredOn:
            mapped = .poweredOn
            resolvePoweredOnWaiters(.success(()))
        case .unauthorized:
            mapped = .unauthorized
            resolvePoweredOnWaiters(.failure(BleTransportError.bluetoothUnauthorized))
        case .poweredOff:
            mapped = .poweredOff
            resolvePoweredOnWaiters(.failure(BleTransportError.bluetoothUnavailable))
        case .unsupported:
            mapped = .unsupported
            resolvePoweredOnWaiters(.failure(BleTransportError.bluetoothUnavailable))
        default:
            mapped = .unknown
        }
        radioState = mapped
        onRadioStateChange?(mapped)
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "Unknown"
        lock.lock()
        knownPeripherals[peripheral.identifier] = peripheral
        let continuation = scanContinuation
        lock.unlock()
        if let filter = scanNameFilter, !name.uppercased().contains(filter.uppercased()) { return }
        continuation?.yield(DiscoveredAdapter(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        gattTreeDescription = "Peripheral: \(peripheral.name ?? "?") \(peripheral.identifier)\n"
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finishConnect(.failure(BleTransportError.connectionFailed(error?.localizedDescription ?? "unknown")))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        lock.lock()
        writeCharacteristic = nil
        notifyCharacteristic = nil
        let hadPendingConnect = connectContinuation != nil
        let intentional = intentionalDisconnect
        intentionalDisconnect = false
        lock.unlock()
        // Mid-connect drop: fail the waiter so connectLoop can back off.
        // Unexpected drop after a live link: notify the controller once.
        finishConnect(.failure(BleTransportError.connectionFailed(error?.localizedDescription ?? "disconnected")))
        if !hadPendingConnect && !intentional {
            onDisconnect?()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension CoreBluetoothTransport: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services, !services.isEmpty else {
            finishConnect(.failure(BleTransportError.noSerialCharacteristics))
            return
        }
        pendingServiceCount = services.count
        for service in services {
            gattTreeDescription += "  Service \(service.uuid)\n"
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            gattTreeDescription += "    Characteristic \(characteristic.uuid) props=\(characteristic.properties.rawValue)\n"
        }
        pendingServiceCount -= 1
        guard pendingServiceCount <= 0 else { return }

        selectSerialCharacteristics(on: peripheral)
        if let notify = notifyCharacteristic, writeCharacteristic != nil {
            peripheral.setNotifyValue(true, for: notify)
        } else {
            finishConnect(.failure(BleTransportError.noSerialCharacteristics))
        }
    }

    private func selectSerialCharacteristics(on peripheral: CBPeripheral) {
        let all = (peripheral.services ?? []).flatMap { $0.characteristics ?? [] }
        let writable = all.filter { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }
        let notifiable = all.filter { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }

        writeCharacteristic = Self.knownWriteUuids.compactMap { uuid in writable.first { $0.uuid == uuid } }.first
            ?? writable.first
        notifyCharacteristic = Self.knownNotifyUuids.compactMap { uuid in notifiable.first { $0.uuid == uuid } }.first
            ?? notifiable.first
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            finishConnect(.failure(BleTransportError.connectionFailed(error.localizedDescription)))
        } else {
            finishConnect(.success(()))
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value, !value.isEmpty else { return }
        incomingContinuation.yield(value)
    }
}
#endif

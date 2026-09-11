import Foundation

/// Byte-level transport to a BLE serial device. Implementations:
/// `CoreBluetoothTransport` (real hardware) and `ReplayTransport` (tests, demo).
///
/// Shared by every device we speak to over a UART-style GATT pipe — ELM327
/// adapters (ObdKit) and RaceBox loggers (RaceBoxKit).
public protocol BleTransport: AnyObject, Sendable {
    /// Raw bytes arriving from the device, in whatever chunks the link delivers.
    /// Never assume one chunk is one protocol message.
    var incoming: AsyncStream<Data> { get }
    /// Send raw bytes to the device.
    func send(_ data: Data) async throws
}

public enum TransportError: Error, Equatable {
    case notConnected
    case writeFailed(String)
}

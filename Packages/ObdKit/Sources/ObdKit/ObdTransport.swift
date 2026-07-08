import Foundation

/// Byte-level transport to an ELM327 adapter. Two implementations:
/// `CoreBluetoothTransport` (real adapter) and `ReplayTransport` (tests, demo mode).
public protocol ObdTransport: AnyObject, Sendable {
    /// Raw bytes arriving from the adapter, in whatever chunks the link delivers.
    var incoming: AsyncStream<Data> { get }
    /// Send raw bytes to the adapter.
    func send(_ data: Data) async throws
}

public enum ObdTransportError: Error, Equatable {
    case notConnected
    case writeFailed(String)
}

@_exported import BleKit

/// The BLE transport layer moved to `BleKit` so RaceBoxKit can share it (and
/// so an OBD adapter and a RaceBox can hold separate links at once). These
/// aliases keep ObdKit's original vocabulary — an ELM327 session still takes
/// an "ObdTransport" — without forcing every call site to rename.
public typealias ObdTransport = BleTransport
public typealias ObdTransportError = TransportError

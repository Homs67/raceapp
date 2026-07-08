import Foundation

/// Connection lifecycle per 06-connection-flow.md §5.
/// Every state maps 1:1 to a status-chip string in the UI.
public enum ObdConnectionState: Equatable, Sendable {
    case idle
    case needsPermission
    case scanning
    case connecting
    case discoveringGatt
    case initializingElm
    case connectingEcu
    case waitingForIgnition
    case live
    case reconnecting(attempt: Int)
}

public enum ObdConnectionEvent: Equatable, Sendable {
    case startRequested
    case permissionDenied
    case permissionGranted
    case peripheralSelected
    case bleConnected
    case gattReady
    case elmReady
    case ecuReady
    case ecuUnavailable      // UNABLE TO CONNECT — ignition off
    case linkLost
    case reconnectFailed     // one reconnect attempt exhausted; backoff and retry
    case stopRequested
}

/// Pure transition function. Returns nil for transitions that must not happen —
/// callers treat nil as a programming error worth logging, never a crash.
public enum ObdConnectionReducer {

    public static func reduce(_ state: ObdConnectionState, _ event: ObdConnectionEvent) -> ObdConnectionState? {
        // Universal events first
        switch event {
        case .stopRequested:
            return .idle
        case .permissionDenied:
            return .needsPermission
        case .linkLost:
            switch state {
            case .connecting, .discoveringGatt, .initializingElm, .connectingEcu, .waitingForIgnition, .live:
                return .reconnecting(attempt: 1)
            case .reconnecting:
                return state
            default:
                return nil
            }
        default:
            break
        }

        switch (state, event) {
        case (.idle, .startRequested):
            return .scanning
        case (.needsPermission, .permissionGranted):
            return .scanning
        case (.scanning, .peripheralSelected):
            return .connecting
        case (.connecting, .bleConnected):
            return .discoveringGatt
        case (.discoveringGatt, .gattReady):
            return .initializingElm
        case (.initializingElm, .elmReady):
            return .connectingEcu
        case (.connectingEcu, .ecuReady):
            return .live
        case (.connectingEcu, .ecuUnavailable):
            return .waitingForIgnition
        case (.waitingForIgnition, .ecuReady):
            return .live
        case (.waitingForIgnition, .ecuUnavailable):
            return .waitingForIgnition          // periodic retry, still off
        case (.reconnecting, .bleConnected):
            return .discoveringGatt             // services must be rediscovered
        case (.reconnecting(let attempt), .reconnectFailed):
            return .reconnecting(attempt: attempt + 1)
        default:
            return nil
        }
    }

    /// Backoff before the next reconnect attempt: 0.5s → 5s cap (per 06 §4).
    public static func reconnectDelay(attempt: Int) -> Duration {
        let seconds = min(5.0, 0.5 * pow(2.0, Double(max(0, attempt - 1))))
        return .milliseconds(Int(seconds * 1000))
    }
}

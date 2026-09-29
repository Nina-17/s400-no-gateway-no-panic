import Foundation

enum PeripheralLinkState {
    case disconnected, connecting, connected, disconnecting
}

enum LinkAction: Equatable {
    case idle, connect, keepPending, inspectServices, awaitDisconnect, cancel
}

enum ConnectionPolicy {
    static func action(armed: Bool, targetID: UUID?, peripheralID: UUID,
                       poweredOn: Bool, state: PeripheralLinkState) -> LinkAction {
        guard poweredOn else { return .idle }
        guard armed, targetID == peripheralID else {
            return state == .connected || state == .connecting ? .cancel : .idle
        }
        switch state {
        case .disconnected: return .connect
        case .connecting: return .keepPending
        case .connected: return .inspectServices
        case .disconnecting: return .awaitDisconnect
        }
    }

    /// No timers are used to keep the process alive. Three terminal callbacks
    /// within a minute pause this unauthenticated PoC to avoid connection churn.
    /// Persist the history so a process restoration cannot reset the budget.
    static func recordingTermination(at now: Date, history: [Date]) -> (history: [Date], pause: Bool) {
        let recent = history.filter { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) < 60 } + [now]
        return (Array(recent.suffix(3)), recent.count >= 3)
    }
}

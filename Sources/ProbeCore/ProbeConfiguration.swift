import Foundation

struct ScaleTarget: Codable, Equatable {
    var identifier: UUID
    var name: String
    // Only available when explicitly included in the MiBeacon advertisement.
    // CoreBluetooth does not expose a peripheral's hardware MAC address.
    var advertisedMAC: String?
    var productID: UInt16?
}

struct ProbeConfiguration: Codable, Equatable {
    var target: ScaleTarget?
    var isArmed = false
    var trialID: UUID?
    var lastBackgroundAt: Date?
    var recentTerminations: [Date] = []
    var lastConnection: ConnectionSnapshot?
}

struct ConnectionSnapshot: Codable, Equatable {
    let date: Date
    let inBackground: Bool
}

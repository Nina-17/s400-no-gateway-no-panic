import Foundation

struct ProbeEvent: Codable {
    let timestamp: Date
    let uptime: TimeInterval
    let processID: Int32
    let runID: UUID
    let trialID: UUID?
    let event: String
    let appState: String
    let protectedDataAvailable: Bool
    let backgroundSeconds: TimeInterval?
    let peripheralID: UUID?
    let details: [String: String]
}

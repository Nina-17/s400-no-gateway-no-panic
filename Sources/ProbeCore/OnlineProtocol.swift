import Foundation

/// Narrow implementation of the authenticated ms103 transcript, not a generic MIoT encoder.
/// The profile comes from this user's successful Mi Home session and is kept verbatim.
struct OnlineProfile: Codable {
    let deviceID: UUID
    let syncTemplate: Data

    init(deviceID: UUID, syncTemplate: Data) throws {
        try Self.validate(syncTemplate)
        self.deviceID = deviceID; self.syncTemplate = syncTemplate
    }

    static func validate(_ data: Data) throws {
        let b = Array(data)
        guard (38...255).contains(b.count), Int(b[0]) == b.count, b[1] == 0x20,
              Array(b[4..<12]) == [5,13,1,5,1,0,2,0x30],
              Array(b[14..<19]) == [2,0,1,0x10,1],
              Array(b[19..<23]) == [4,0,4,0x50],
              Array(b[27..<36]) == [3,0,1,0,1,5,0,UInt8(b.count-36),0xa0],
              let object = try JSONSerialization.jsonObject(with: Data(b[36...])) as? [String: Any],
              let users = object["ud"] as? [[String: Any]], !users.isEmpty,
              let count = object["uc"] as? Int, count == users.count,
              let mid = object["mid"] as? String, UInt64(mid) != nil,
              let hash = object["hash"] as? String, !hash.isEmpty else { throw ScaleProtocolError.schema }
    }

    func sync(sequence: UInt16, now: Date) throws -> Data {
        try Self.validate(syncTemplate)
        let timestamp = now.timeIntervalSince1970
        guard timestamp.isFinite, (1_577_836_800...4_102_444_800).contains(timestamp) else { throw ScaleProtocolError.schema }
        var data = syncTemplate
        data[2] = UInt8(sequence & 255); data[3] = UInt8(sequence >> 8)
        let seconds = UInt32(timestamp)
        for index in 0..<4 { data[23+index] = UInt8((seconds >> (index * 8)) & 255) }
        return data
    }
}

enum OnlineMessage {
    case hello, syncResponse(sequence: UInt16), live(weightKg: Double, phase: Int), body([String])

    static func parse(_ data: Data) throws -> Self {
        let b = Array(data)
        guard (5...255).contains(b.count), Int(b[0]) == b.count, b[1] == 0x20 else { throw ScaleProtocolError.schema }
        if data == Data([5,0x20,0,0,0xf0]) { return .hello }
        if b[4] == 6 {
            guard b.count >= 8, b[5] == 0, b[6] == 0, b[7] == 5 else { throw ScaleProtocolError.rejected }
            var offset = 8
            for expected in 6...10 {
                guard offset + 4 <= b.count, Int(b[offset]) == expected, b[offset+1] == 0 else { throw ScaleProtocolError.schema }
                let length = Int(b[offset+2]); let type = b[offset+3]
                guard type == ((expected == 6 || expected == 10) ? 0x10 : 0xa0),
                      offset + 4 + length <= b.count else { throw ScaleProtocolError.schema }
                offset += 4 + length
            }
            guard offset == b.count else { throw ScaleProtocolError.schema }
            return .syncResponse(sequence: UInt16(b[2]) | UInt16(b[3]) << 8)
        }
        guard b.count >= 13, b[4] == 7, b[5] == 8, (1...2).contains(b[6]),
              b[7] == 0, b[8] == 1, b[9] == b[6], b[10] == 0,
              Int(b[11]) == b.count - 13, b[12] == 0xa0,
              let csv = String(data: Data(b[13...]), encoding: .ascii) else { throw ScaleProtocolError.schema }
        let fields = csv.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.allSatisfy({ field in
            let digits = field.first == "-" ? field.dropFirst() : field[...]
            return field.count <= 20 && !digits.isEmpty && digits.utf8.allSatisfy { (48...57).contains($0) } && Int64(field) != nil
        }) else { throw ScaleProtocolError.schema }
        if b[6] == 1 {
            guard fields.count == 2, let weight = Int(fields[0]), (0...3000).contains(weight),
                  let phase = Int(fields[1]), (0...2).contains(phase) else { throw ScaleProtocolError.schema }
            return .live(weightKg: Double(weight)/10, phase: phase)
        }
        guard fields.count == 32 else { throw ScaleProtocolError.schema }
        return .body(fields)
    }
}

/// Each next command requires both the transport ACK and matching business reply.
final class OnlineInitialization {
    enum Stage: String { case hello, syncFirst, syncSecond, ready }
    private(set) var stage: Stage = .hello
    private var sent = false
    private var replied = false
    private(set) var deadline: Date?
    let profile: OnlineProfile
    init(profile: OnlineProfile) { self.profile = profile }

    func start(at now: Date) -> Data {
        deadline = now.addingTimeInterval(10)
        return Data([5,0x20,0,0,0xf0])
    }
    func acknowledge(at now: Date) throws -> Data? {
        guard stage != .ready, !sent else { throw ScaleProtocolError.framing }
        sent = true
        return try advance(at: now)
    }
    func receive(_ message: OnlineMessage, at now: Date) throws -> Data? {
        switch (stage, message) {
        case (.hello, .hello), (.syncFirst, .syncResponse(sequence: 1)), (.syncSecond, .syncResponse(sequence: 2)):
            guard !replied else { throw ScaleProtocolError.framing }
            replied = true
        default: throw ScaleProtocolError.schema
        }
        return try advance(at: now)
    }
    private func advance(at now: Date) throws -> Data? {
        guard let deadline, now < deadline else { throw ScaleProtocolError.timeout }
        guard sent && replied else { return nil }
        sent = false; replied = false
        switch stage {
        case .hello: stage = .syncFirst
        case .syncFirst: stage = .syncSecond
        case .syncSecond: stage = .ready; self.deadline = nil; return nil
        case .ready: throw ScaleProtocolError.framing
        }
        self.deadline = now.addingTimeInterval(10)
        return try profile.sync(sequence: stage == .syncFirst ? 1 : 2, now: now)
    }
}

struct OnlineBodyReport: Codable {
    let deviceID: UUID
    let receivedAt: Date
    let inBackground: Bool
    let fields: [String]
}

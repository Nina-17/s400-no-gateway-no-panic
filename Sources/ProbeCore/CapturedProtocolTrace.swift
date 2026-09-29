import Foundation
import CryptoKit

/// Offline diagnosis only. Credentials and derived keys never appear in the report.
struct CapturedProtocolTrace: Codable {
    let deviceID: UUID
    let appRandom, deviceRandom, appHMAC, remoteHMAC: String
    struct Packet: Codable {
        let channel, direction: String
        let offset: Double
        let data: String
    }
    let packets: [Packet]

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 1_000_000 else { throw ScaleProtocolError.schema }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func analyze(token: Data, expectedID: UUID) throws -> [Packet] {
        guard deviceID == expectedID, (1...128).contains(packets.count) else { throw ScaleProtocolError.schema }
        let app = try Self.hex(appRandom), device = try Self.hex(deviceRandom)
        let keys = try SessionKeys.derive(token: token, appRandom: app, deviceRandom: device)
        guard keys.verifiesRemote(try Self.hex(remoteHMAC), appRandom: app, deviceRandom: device),
              CryptoKit.HMAC<CryptoKit.SHA256>.isValidAuthenticationCode(try Self.hex(appHMAC),
                authenticating: app + device, using: SymmetricKey(data: keys.appKey)) else {
            throw ScaleProtocolError.authentication
        }
        var counters: [String: Int] = [:]
        return try packets.map { packet in
            guard (packet.channel == "001A" && packet.direction == "send") ||
                  (packet.channel == "001B" && packet.direction == "receive"),
                  packet.offset.isFinite, (0...600).contains(packet.offset) else { throw ScaleProtocolError.schema }
            let cipher = try Self.hex(packet.data)
            guard (7...4096).contains(cipher.count) else { throw ScaleProtocolError.ciphertext }
            let counter = Int(cipher[0]) | Int(cipher[1]) << 8
            if let previous = counters[packet.direction], counter <= previous { throw ScaleProtocolError.replay }
            let plain = try keys.decrypt(cipher, fromApp: packet.direction == "send")
            counters[packet.direction] = counter
            return Packet(channel: packet.channel, direction: packet.direction, offset: packet.offset,
                          data: plain.map { String(format: "%02x", $0) }.joined())
        }
    }

    private static func hex(_ text: String) throws -> Data {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 8192, bytes.count.isMultiple(of: 2),
              bytes.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw ScaleProtocolError.schema
        }
        return Data(stride(from: 0, to: bytes.count, by: 2).map {
            UInt8(String(decoding: bytes[$0..<$0+2], as: UTF8.self), radix: 16)!
        })
    }
}

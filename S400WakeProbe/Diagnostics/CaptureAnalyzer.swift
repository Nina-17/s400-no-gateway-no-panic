#if DEBUG
import Foundation

enum CaptureAnalyzer {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("--analyze-capture") }
    static func run() {
        guard let storage = try? ProbeStorage() else { return }
        let output = storage.directory.appendingPathComponent("capture-output.json")
        do {
            let config = try storage.load()
            guard !config.isArmed, let id = config.target?.identifier else { throw ScaleProtocolError.rejected }
            let input = storage.directory.appendingPathComponent("capture-input.json")
            let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 1_000_000 else { throw ScaleProtocolError.schema }
            let trace = try CapturedProtocolTrace.parse(Data(contentsOf: input))
            guard let token = try ScaleCredentials.read(for: id) else { throw ScaleProtocolError.authentication }
            let packets = try trace.analyze(token: token, expectedID: id)
            func bytes(_ text: String) -> Data {
                Data(stride(from: 0, to: text.count, by: 2).map { offset -> UInt8 in
                    let start = text.index(text.startIndex, offsetBy: offset)
                    return UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16)!
                })
            }
            let syncPackets = packets.filter { $0.direction == "send" }.compactMap { packet -> Data? in
                let data = bytes(packet.data)
                return (try? OnlineProfile.validate(data)) != nil ? data : nil
            }
            guard syncPackets.count == 2 else { throw ScaleProtocolError.schema }
            let profile = try OnlineProfile(deviceID: id, syncTemplate: syncPackets[0])
            var successful = Set<UInt16>()
            var bodyCount = 0
            for packet in packets where packet.direction == "receive" {
                let data = bytes(packet.data)
                // The final update-base-weight action response has no return values.
                if data == Data([7,0x20,3,0,6,0,0]) { continue }
                switch try OnlineMessage.parse(data) {
                case .syncResponse(let sequence): successful.insert(sequence)
                case .body: bodyCount += 1
                default: break
                }
            }
            guard successful == [1,2], bodyCount == 1 else { throw ScaleProtocolError.schema }
            var normalized = syncPackets[1]; normalized[2] = syncPackets[0][2]; normalized[3] = syncPackets[0][3]
            guard normalized == syncPackets[0] else { throw ScaleProtocolError.schema }
            try JSONEncoder().encode(profile).write(to: storage.directory.appendingPathComponent("online-profile.json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(packets).write(to: output, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            let code = (error as? ScaleProtocolError)?.rawValue ?? "diagnostic_io"
            let data = try? JSONEncoder().encode(["error": code])
            try? data?.write(to: output, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
#endif

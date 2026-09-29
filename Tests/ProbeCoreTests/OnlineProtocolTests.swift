import XCTest
@testable import ProbeCore

final class OnlineProtocolTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_400_000)
    func profile() throws -> OnlineProfile {
        // Public synthetic profile, no real identifiers, hash, or body values.
        let json = Data(#"{"mid":"12345","uid":1,"uc":1,"ow":1,"hash":"synthetic","ud":[{"uid":1,"ut":1,"age":30,"sex":1,"hi":170,"wt":700,"time":1790400000}]}"#.utf8)
        var b = Data([0,0x20,1,0,5,13,1,5,1,0,2,0x30,0xa7,0,2,0,1,0x10,1,4,0,4,0x50,0,0,0,0,3,0,1,0,1,5,0,UInt8(json.count),0xa0]) + json
        b[0] = UInt8(b.count)
        return try OnlineProfile(deviceID: UUID(), syncTemplate: b)
    }
    func response(sequence: UInt16) -> Data {
        var data = Data([0,0x20,UInt8(sequence),0,6,0,0,5])
        for i in 6...10 { data += Data([UInt8(i),0,1,(i == 6 || i == 10) ? 0x10 : 0xa0,0]) }
        data[0] = UInt8(data.count); return data
    }
    func event(_ event: UInt8, _ text: String) -> Data {
        let csv = Data(text.utf8)
        return Data([UInt8(csv.count+13),0x20,3,0,7,8,event,0,1,event,0,UInt8(csv.count),0xa0]) + csv
    }
    func testProfilePreservesOriginalUserJSONAndOnlyUpdatesSequenceAndClock() throws {
        let p = try profile(), synced = try p.sync(sequence: 2, now: now)
        XCTAssertEqual(synced.suffix(from: 27), p.syncTemplate.suffix(from: 27))
        XCTAssertEqual(synced[2], 2)
        XCTAssertEqual((0..<4).reduce(UInt32(0)) { $0 | UInt32(synced[23+$1]) << ($1*8) }, 1_790_400_000)
        var bad = p.syncTemplate; bad[31] = 0 // Do not silently disable heart-rate detection.
        XCTAssertThrowsError(try OnlineProfile.validate(bad))
        bad = p.syncTemplate; bad[0] = 0
        XCTAssertThrowsError(try OnlineProfile.validate(bad))
    }
    func testInitializationRequiresMatchingBusinessReplyAndTransportAckEitherOrder() throws {
        for replyFirst in [true,false] {
            let state = OnlineInitialization(profile: try profile())
            XCTAssertEqual(state.start(at: now), Data([5,0x20,0,0,0xf0]))
            for (index, msg) in [OnlineMessage.hello, .syncResponse(sequence: 1), .syncResponse(sequence: 2)].enumerated() {
                if replyFirst {
                    XCTAssertNil(try state.receive(msg, at: now))
                    let next = try state.acknowledge(at: now)
                    XCTAssertEqual(next == nil, index == 2)
                } else {
                    XCTAssertNil(try state.acknowledge(at: now))
                    let next = try state.receive(msg, at: now)
                    XCTAssertEqual(next == nil, index == 2)
                }
            }
            XCTAssertEqual(state.stage, .ready); XCTAssertNil(state.deadline)
        }
    }
    func testWrongReplyAndTimeoutCannotMarkInitializationSuccessful() throws {
        let state = OnlineInitialization(profile: try profile()); _ = state.start(at: now)
        XCTAssertThrowsError(try state.receive(.syncResponse(sequence: 2), at: now))
        _ = try state.acknowledge(at: now)
        XCTAssertThrowsError(try state.receive(.hello, at: now.addingTimeInterval(11)))
        XCTAssertNotEqual(state.stage, .ready)
    }
    func testStrictBusinessEnvelopesAndSignedBodyFields() throws {
        guard case .syncResponse(sequence: 1) = try OnlineMessage.parse(response(sequence: 1)) else { return XCTFail() }
        var rejected = response(sequence: 1); rejected[5] = 1
        XCTAssertThrowsError(try OnlineMessage.parse(rejected))
        guard case .live(weightKg: 70, phase: 2) = try OnlineMessage.parse(event(1,"700,2")) else { return XCTFail() }
        var fields = Array(repeating: "0", count: 32); fields[0] = "12345"; fields[3] = "700"; fields[16] = "-19"
        guard case .body(let parsed) = try OnlineMessage.parse(event(2, fields.joined(separator: ","))) else { return XCTFail() }
        XCTAssertEqual(parsed, fields)
        XCTAssertThrowsError(try OnlineMessage.parse(event(2,"700,1")))
        var wrongService = event(1,"700,1"); wrongService[5] = 9
        XCTAssertThrowsError(try OnlineMessage.parse(wrongService))
        var wrongLength = event(1,"700,1"); wrongLength[11] = 1
        XCTAssertThrowsError(try OnlineMessage.parse(wrongLength))
    }
}

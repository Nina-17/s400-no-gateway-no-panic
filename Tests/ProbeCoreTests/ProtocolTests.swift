import XCTest
import CryptoSwift
@testable import ProbeCore

final class ProtocolTests: XCTestCase {
    struct Vectors: Decodable {
        let token, appRandom, deviceRandom, deviceKey, appKey, deviceIV, appIV, remoteHMAC, appHMAC: String
        struct Packet: Decodable { let counter: Int; let plaintext, packet: String }
        let packets, appPackets: [Packet]
    }
    let now = Date(timeIntervalSince1970: 1_790_400_000)
    func vectors() throws -> Vectors {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "protocol-vectors", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }
    func hex(_ text: String) -> Data { Data(Array<UInt8>(hex: text)) }
    func keys(_ v: Vectors) throws -> SessionKeys {
        try SessionKeys.derive(token: hex(v.token), appRandom: hex(v.appRandom), deviceRandom: hex(v.deviceRandom))
    }
    func feed(_ data: Data, to session: MiHomeSession, channel: ScaleChannel = .auth) throws -> [MiHomeSession.Effect] {
        let count = (data.count + 17) / 18
        var effects = try session.receive(Data([0, 0, 0, 3, UInt8(count), 0]), on: channel, at: now)
        for frame in ParcelReceiver.frames(data) { effects += try session.receive(frame, on: channel, at: now) }
        return effects
    }
    func authenticating(_ v: Vectors) throws -> MiHomeSession {
        let s = try MiHomeSession(token: hex(v.token), random: hex(v.appRandom))
        let effects = try s.start(at: now)
        guard case .write(let command) = effects[0] else { throw ScaleProtocolError.framing }
        XCTAssertEqual(command, ScaleWrite(channel: .command, data: Data([0x24, 0, 0, 0])))
        _ = try s.receive(MiHomeSession.ready, on: .auth, at: now)
        _ = try s.receive(MiHomeSession.ok, on: .auth, at: now)
        _ = try feed(hex(v.deviceRandom), to: s)
        return s
    }
    func streaming(_ v: Vectors, confirmationFirst: Bool = false) throws -> MiHomeSession {
        let s = try authenticating(v)
        _ = try feed(hex(v.remoteHMAC), to: s)
        let our = try s.receive(MiHomeSession.ready, on: .auth, at: now)
        let sent = our.compactMap { effect -> Data? in
            guard case .write(let write) = effect else { return nil }; return Data(write.data.dropFirst(2))
        }.reduce(Data(), +)
        XCTAssertEqual(sent, hex(v.appHMAC))
        if confirmationFirst { _ = try s.receive(Data([0x21, 0, 0, 0]), on: .command, at: now) }
        _ = try s.receive(MiHomeSession.ok, on: .auth, at: now)
        if !confirmationFirst { _ = try s.receive(Data([0x21, 0, 0, 0]), on: .command, at: now) }
        XCTAssertEqual(s.stage, .streaming)
        return s
    }

    func testTokenStrictnessAndNoBindkeyConfusion() throws {
        XCTAssertEqual(try TokenFormat.parse(" 000102030405060708090A0B\n"), Data(0..<12))
        for text in ["", String(repeating: "0", count: 32), String(repeating: "g", count: 24), "000102030405 0708090a0b"] {
            XCTAssertThrowsError(try TokenFormat.parse(text))
        }
    }
    func testHKDFAndBothHMACsMatchIndependentPython() throws {
        let v = try vectors(), k = try keys(v)
        XCTAssertEqual(k.deviceKey, hex(v.deviceKey)); XCTAssertEqual(k.appKey, hex(v.appKey))
        XCTAssertEqual(k.deviceIV, hex(v.deviceIV)); XCTAssertEqual(k.appIV, hex(v.appIV))
        XCTAssertTrue(k.verifiesRemote(hex(v.remoteHMAC), appRandom: hex(v.appRandom), deviceRandom: hex(v.deviceRandom)))
        XCTAssertEqual(SessionKeys.hmac(key: k.appKey, message: hex(v.appRandom) + hex(v.deviceRandom)), hex(v.appHMAC))
        XCTAssertFalse(k.verifiesRemote(Data(repeating: 0, count: 32), appRandom: hex(v.appRandom), deviceRandom: hex(v.deviceRandom)))
    }
    func testCCMPythonPacketsAndEveryBitOfTagCorruption() throws {
        let v = try vectors(), k = try keys(v)
        for packet in v.packets {
            let cipher = hex(packet.packet)
            XCTAssertEqual(try k.decrypt(cipher), hex(packet.plaintext))
            for index in cipher.count-4..<cipher.count {
                for bit in 0..<8 {
                    var corrupted = cipher; corrupted[index] ^= 1 << bit
                    XCTAssertThrowsError(try k.decrypt(corrupted))
                }
            }
            var counter = cipher; counter[0] ^= 1
            XCTAssertThrowsError(try k.decrypt(counter))
        }
        XCTAssertThrowsError(try k.decrypt(Data(repeating: 0, count: 6)))
    }

    func testOfflineCaptureBothDirectionsAndFailClosed() throws {
        let v = try vectors(), id = UUID()
        let packets = zip(v.appPackets, v.packets).flatMap { sent, received in [
            CapturedProtocolTrace.Packet(channel: "001A", direction: "send", offset: 1, data: sent.packet),
            CapturedProtocolTrace.Packet(channel: "001B", direction: "receive", offset: 2, data: received.packet)]
        }
        func trace(_ packets: [CapturedProtocolTrace.Packet], appHMAC: String? = nil) -> CapturedProtocolTrace {
            CapturedProtocolTrace(deviceID: id, appRandom: v.appRandom, deviceRandom: v.deviceRandom,
                                 appHMAC: appHMAC ?? v.appHMAC, remoteHMAC: v.remoteHMAC, packets: packets)
        }
        let result = try trace(packets).analyze(token: hex(v.token), expectedID: id)
        XCTAssertEqual(result.map(\.data), zip(v.appPackets, v.packets).flatMap { [$0.plaintext, $1.plaintext] })
        XCTAssertThrowsError(try trace(packets).analyze(token: hex(v.token), expectedID: UUID()))
        XCTAssertThrowsError(try trace(packets, appHMAC: String(repeating: "00", count: 32)).analyze(token: hex(v.token), expectedID: id))
        XCTAssertThrowsError(try trace(packets + [packets[0]]).analyze(token: hex(v.token), expectedID: id))
        XCTAssertThrowsError(try trace(Array(repeating: packets[0], count: 129)).analyze(token: hex(v.token), expectedID: id))
        var corrupted = hex(packets[0].data); corrupted[corrupted.count-1] ^= 1
        let bad = CapturedProtocolTrace.Packet(channel: "001A", direction: "send", offset: 1,
                                               data: corrupted.map { String(format: "%02x", $0) }.joined())
        XCTAssertThrowsError(try trace([bad]).analyze(token: hex(v.token), expectedID: id))
        XCTAssertThrowsError(try CapturedProtocolTrace.parse(Data(repeating: 0, count: 1_000_001)))
    }

    func testOutboundEncryptionAndTransportMatchIndependentOracle() throws {
        let v = try vectors(), k = try keys(v)
        for p in v.appPackets {
            XCTAssertEqual(try k.encryptForDevice(hex(p.plaintext), counter: UInt16(p.counter)), hex(p.packet))
        }
        let s = try streaming(v)
        let plain = hex(v.appPackets[0].plaintext)
        let header = try s.sendApplication(plain, at: now)
        guard case .write(let headerWrite) = header.first else { return XCTFail() }
        XCTAssertEqual(headerWrite.channel, .application)
        XCTAssertEqual(headerWrite.data, Data([0,0,0,0,1,0]))
        XCTAssertThrowsError(try s.sendApplication(plain, at: now))
        let effects = try s.receive(MiHomeSession.ready, on: .application, at: now)
        let cipher = effects.compactMap { e -> Data? in
            guard case .write(let w) = e else { return nil }; return Data(w.data.dropFirst(2))
        }.reduce(Data(), +)
        XCTAssertEqual(cipher.prefix(2), Data([0,0]))
        XCTAssertEqual(try k.decrypt(cipher, fromApp: true), plain)
        // Incoming parcels must not clear a pending outgoing ACK's deadline.
        _ = try feed(hex(v.packets[0].packet), to: s, channel: .measurement)
        XCTAssertNotNil(s.deadline)
        XCTAssertThrowsError(try s.checkDeadline(at: now.addingTimeInterval(9)))
        let result = try s.receive(MiHomeSession.ok, on: .application, at: now)
        guard case .applicationSent = result.first else { return XCTFail("Missing send confirmation") }
        XCTAssertNil(s.deadline)
        _ = try s.sendApplication(plain, at: now)
    }
    func testRFC3610PacketVectorOne() throws {
        // RFC 3610 §8 packet vector #1: first 8 bytes are AAD, remaining 23 encrypted.
        let key = Array<UInt8>(hex: "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf")
        let nonce = Array<UInt8>(hex: "00000003020100a0a1a2a3a4a5")
        let mode = CCM(iv: nonce, tagLength: 8, messageLength: 23,
                       additionalAuthenticatedData: Array(0..<8))
        let encrypted = Array<UInt8>(hex: "588c979a61c663d2f066d0c2c0f989806d5f6b61dac38417e8d12cfdf926e0")
        XCTAssertEqual(try AES(key: key, blockMode: mode, padding: .noPadding).decrypt(encrypted), Array(8..<31))
    }
    func testLoginAndEncryptedMeasurementTranscript() throws {
        let v = try vectors()
        for reversed in [false, true] {
            let s = try streaming(v, confirmationFirst: reversed)
            for p in v.packets {
                let effects = try feed(hex(p.packet), to: s, channel: .measurement)
                let payloads = effects.compactMap { effect -> Data? in
                    guard case .payload(let data) = effect else { return nil }; return data
                }
                XCTAssertEqual(payloads, [hex(p.plaintext)])
            }
            XCTAssertThrowsError(try feed(hex(v.packets.last!.packet), to: s, channel: .measurement))
        }
    }
    func testWrongTokenAndEarlyMeasurementAreRejected() throws {
        let v = try vectors(), s = try authenticating(v)
        XCTAssertThrowsError(try feed(Data(repeating: 0, count: 32), to: s))
        let early = try MiHomeSession(token: hex(v.token), random: hex(v.appRandom))
        _ = try early.start(at: now)
        XCTAssertThrowsError(try feed(hex(v.packets[0].packet), to: early, channel: .measurement))
        XCTAssertThrowsError(try early.receive(Data([0x23, 0, 0, 0]), on: .command, at: now))
    }
    func testTimeoutAcrossSuspensionRejectsLateNotification() throws {
        let v = try vectors(), s = try MiHomeSession(token: hex(v.token), random: hex(v.appRandom))
        _ = try s.start(at: now)
        XCTAssertThrowsError(try s.receive(MiHomeSession.ready, on: .auth, at: now.addingTimeInterval(9)))
        let active = try streaming(v)
        _ = try active.receive(Data([0, 0, 0, 3, 2, 0]), on: .measurement, at: now)
        XCTAssertThrowsError(try active.checkDeadline(at: now.addingTimeInterval(9)))
    }
    func testParcelRejectsMissingDuplicateOutOfOrderAndOversizedFrames() throws {
        for invalid in [Data([2, 0, 1]), Data([1, 0, 1]), Data([0, 0, 0, 3, 1, 0])] {
            var p = ParcelReceiver()
            _ = try p.receive(Data([0, 0, 0, 3, 2, 0]))
            XCTAssertThrowsError(try p.receive(invalid))
        }
        var p = ParcelReceiver()
        XCTAssertThrowsError(try p.receive(Data([0, 0, 0, 3, 255, 255])))
        _ = try p.receive(Data([0, 0, 0, 3, 2, 0]))
        let first = Data([1, 0]) + Data(repeating: 1, count: 18)
        _ = try p.receive(first)
        XCTAssertThrowsError(try p.receive(first))
        XCTAssertThrowsError(try p.receive(Data([2, 0]) + Data(repeating: 1, count: 19)))
    }
    func testCandidateParserRequiresFullSchemaAndStableIdentity() throws {
        let v = try vectors(), id = UUID()
        let payload = hex(v.packets.last!.plaintext)
        guard case .candidate(let m) = ScalePayload.parse(payload, deviceID: id, receivedAt: now, inBackground: true),
              case .candidate(let replay) = ScalePayload.parse(payload, deviceID: id, receivedAt: now.addingTimeInterval(20), inBackground: false) else {
            return XCTFail("Valid documented final rejected")
        }
        XCTAssertEqual(m.weightKg, 70); XCTAssertEqual(m.impedance, 500)
        XCTAssertEqual(m.lowFrequencyImpedance, 600); XCTAssertEqual(m.profileID, 7)
        XCTAssertEqual(m.id, replay.id); XCTAssertFalse(m.timeNeedsReview)
        for csv in ["0,0,7,700,1,2,1790400000,5000,6000", "700,1,", "-700,1", "nan,1"] {
            guard case .unsupported = ScalePayload.parse(Data([0xa0]) + Data(csv.utf8), deviceID: id, receivedAt: now, inBackground: false) else {
                return XCTFail("Unsafe schema accepted")
            }
        }
        guard case .live(let weight, let stable) = ScalePayload.parse(hex(v.packets[0].plaintext), deviceID: id, receivedAt: now, inBackground: false) else {
            return XCTFail("Live packet rejected")
        }
        XCTAssertEqual(weight, 70); XCTAssertTrue(stable)
    }

    func testObservedZeroFlagIsOnlyACandidateAndLegacyRecordsDecode() throws {
        // Synthetic values with the observed real-device shape; no private sample copied.
        let fields = ["0", "0", "1", "700", "0", "2", "1790400000"] + Array(repeating: "0", count: 23) + ["5000", "4500"]
        let data = Data([0xa0]) + Data(fields.joined(separator: ",").utf8)
        guard case .candidate(let m) = ScalePayload.parse(data, deviceID: UUID(), receivedAt: now, inBackground: false) else {
            return XCTFail("Observed shape must be retained as candidate")
        }
        XCTAssertEqual(m.reportedFlag4, 0)
        XCTAssertEqual(m.impedance, 500)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as? [String: Any])
        json.removeValue(forKey: "reportedFlag4")
        let legacy = try JSONDecoder().decode(ScaleMeasurement.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.reportedFlag4)
        XCTAssertEqual(legacy.id, m.id)
    }

    func testInspectionExplainsAllRejectedFieldsWithoutLoggingTheirValues() {
        var fields = ["0", "0", "4294967295", "700", "0", "2", "0"] + Array(repeating: "0", count: 23) + ["5000", "6000"]
        fields[10] = "-1"
        fields[4] = "2"
        let data = Data([0xa0]) + Data(fields.joined(separator: ",").utf8)
        let inspection = ScalePacketInspection.inspect(data)
        XCTAssertEqual(inspection.fieldCount, 32)
        XCTAssertEqual(inspection.numericFields, fields)
        XCTAssertTrue(inspection.issues.contains("profile_out_of_range"))
        XCTAssertTrue(inspection.issues.contains("timestamp_out_of_range"))
        XCTAssertTrue(inspection.issues.contains("unknown_flag4"))
        XCTAssertTrue(inspection.issues.contains("non_unsigned_integer_10"))
        guard case .unsupported = ScalePayload.parse(data, deviceID: UUID(), receivedAt: now, inBackground: false) else {
            return XCTFail("Diagnostics must not turn an unknown packet into a final")
        }
        XCTAssertNil(ScalePacketInspection.inspect(Data([0xa0]) + Data("password,notnumeric".utf8)).numericFields)
        XCTAssertNil(ScalePacketInspection.inspect(Data([0xa0]) + Data(Array(repeating: "0", count: 65).joined(separator: ",").utf8)).numericFields)
    }
}

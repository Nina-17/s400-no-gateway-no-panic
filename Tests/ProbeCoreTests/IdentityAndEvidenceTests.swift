import XCTest
@testable import ProbeCore

final class IdentityAndEvidenceTests: XCTestCase {
    func testMiBeaconHeaderReversesOnlyAdvertisedMAC() throws {
        let header = Data([0x10, 0x50, 0xD9, 0x30, 1, 0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA])
        let identity = try XCTUnwrap(MiBeaconIdentity(serviceData: header))
        XCTAssertEqual(identity.productID, 0x30D9)
        XCTAssertEqual(identity.advertisedMAC, "AA:BB:CC:DD:EE:FF")
        XCTAssertTrue(identity.isKnownScaleFamily)
        let noMAC = try XCTUnwrap(MiBeaconIdentity(serviceData: Data([0, 0x50, 0xD9, 0x30, 1])))
        XCTAssertNil(noMAC.advertisedMAC)
    }

    func testTruncatedOrOldHeadersDoNotInventIdentity() {
        for count in 0..<5 { XCTAssertNil(MiBeaconIdentity(serviceData: Data(repeating: 0, count: count))) }
        XCTAssertNil(MiBeaconIdentity(serviceData: Data([0x10, 0x50, 0xD9, 0x30, 1, 0xFF])))
        XCTAssertNil(MiBeaconIdentity(serviceData: Data([0, 0x20, 0xD9, 0x30, 1])))
        let other = MiBeaconIdentity(serviceData: Data([0, 0x50, 1, 2, 1]))
        XCTAssertEqual(other?.isKnownScaleFamily, false)
    }

    func testSlicedDataUsesRelativeOffsets() {
        let bytes = Data([255, 255, 0, 0x50, 0xD9, 0x30, 1])
        XCTAssertEqual(MiBeaconIdentity(serviceData: bytes.dropFirst(2))?.productID, 0x30D9)
    }

    func testEvidencePreservesRunTrialAndBackgroundState() throws {
        let event = ProbeEvent(timestamp: Date(), uptime: 42, processID: 100, runID: UUID(),
            trialID: UUID(), event: "connected", appState: "background", protectedDataAvailable: false,
            backgroundSeconds: 901, peripheralID: UUID(), details: [:])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(ProbeEvent.self, from: encoder.encode(event))
        XCTAssertEqual(restored.runID, event.runID)
        XCTAssertEqual(restored.trialID, event.trialID)
        XCTAssertEqual(restored.backgroundSeconds, 901)
        XCTAssertEqual(restored.appState, "background")
        XCTAssertFalse(restored.protectedDataAvailable)
    }
}

import XCTest
@testable import ProbeCore

final class ConnectionPolicyTests: XCTestCase {
    private let target = UUID()

    func testSleepingTargetIsConnectedAndExistingPendingRequestIsPreserved() {
        XCTAssertEqual(decision(.disconnected), .connect)
        // Repeated poweredOn/foreground/restoration reconciliation must not
        // cancel and restart the long-lived system connection request.
        for _ in 0..<100 { XCTAssertEqual(decision(.connecting), .keepPending) }
    }

    func testRestoredConnectedDeviceContinuesAndDisconnectingWaitsForCallback() {
        XCTAssertEqual(decision(.connected), .inspectServices)
        XCTAssertEqual(decision(.disconnecting), .awaitDisconnect)
    }

    func testUserStopAndStaleTargetCannotRearmFromALateCallback() {
        XCTAssertEqual(decision(.connected, armed: false), .cancel)
        XCTAssertEqual(decision(.connecting, armed: false), .cancel)
        XCTAssertEqual(decision(.disconnected, armed: false), .idle)
        XCTAssertEqual(ConnectionPolicy.action(armed: true, targetID: target,
            peripheralID: UUID(), poweredOn: true, state: .connected), .cancel)
        XCTAssertEqual(ConnectionPolicy.action(armed: true, targetID: nil,
            peripheralID: target, poweredOn: true, state: .disconnected), .idle)
    }

    func testBluetoothOffDoesNotIssueOperations() {
        for state in [PeripheralLinkState.disconnected, .connecting, .connected, .disconnecting] {
            XCTAssertEqual(decision(state, poweredOn: false), .idle)
        }
    }

    func testRapidFailuresPauseButNextDayDisconnectRearms() {
        let now = Date(timeIntervalSince1970: 1_000)
        let first = ConnectionPolicy.recordingTermination(at: now, history: [])
        XCTAssertFalse(first.pause)
        let second = ConnectionPolicy.recordingTermination(at: now.addingTimeInterval(10), history: first.history)
        XCTAssertFalse(second.pause)
        let third = ConnectionPolicy.recordingTermination(at: now.addingTimeInterval(20), history: second.history)
        XCTAssertTrue(third.pause)
        let tomorrow = ConnectionPolicy.recordingTermination(at: now.addingTimeInterval(86_400), history: third.history)
        XCTAssertFalse(tomorrow.pause)
        XCTAssertEqual(tomorrow.history.count, 1)
    }

    func testConfigurationRoundTripPreservesIntentAndFailureBudgetAcrossRelaunch() throws {
        let original = ProbeConfiguration(
            target: ScaleTarget(identifier: target, name: "S400", advertisedMAC: nil, productID: 0x30D9),
            isArmed: true, trialID: UUID(), lastBackgroundAt: Date(timeIntervalSince1970: 100),
            recentTerminations: [Date(timeIntervalSince1970: 101), Date(timeIntervalSince1970: 102)])
        let restored = try JSONDecoder().decode(ProbeConfiguration.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
        XCTAssertTrue(ConnectionPolicy.recordingTermination(at: Date(timeIntervalSince1970: 103),
            history: restored.recentTerminations).pause)
    }

    private func decision(_ state: PeripheralLinkState, armed: Bool = true, poweredOn: Bool = true) -> LinkAction {
        ConnectionPolicy.action(armed: armed, targetID: target, peripheralID: target,
                                poweredOn: poweredOn, state: state)
    }
}

import XCTest
@testable import ProbeCore

final class ConfigurationMigrationTests: XCTestCase {
    func testOldExperimentConfigurationKeepsTheScaleAndMonitoringState() throws {
        let deviceID = UUID()
        let trialID = UUID()
        let legacy = """
        {
          "target": {"identifier": "\(deviceID.uuidString)", "name": "S400", "advertisedMAC": "02:00:00:00:00:01", "productID": 12505},
          "isArmed": true,
          "trialID": "\(trialID.uuidString)",
          "recentTerminations": [],
          "connectionTest": {"id": "\(trialID.uuidString)", "delaySeconds": 900, "phase": "finished"},
          "lastConnection": {"date": 0, "inBackground": true}
        }
        """
        let restored = try JSONDecoder().decode(ProbeConfiguration.self, from: Data(legacy.utf8))
        XCTAssertEqual(restored.target?.identifier, deviceID)
        XCTAssertEqual(restored.target?.name, "S400")
        XCTAssertTrue(restored.isArmed)
        XCTAssertEqual(restored.trialID, trialID)
        XCTAssertEqual(restored.lastConnection?.inBackground, true)
        let saved = try String(decoding: JSONEncoder().encode(restored), as: UTF8.self)
        XCTAssertFalse(saved.contains("connectionTest"))
    }
}

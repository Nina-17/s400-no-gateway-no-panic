import XCTest
@testable import ProbeCore

final class MeasurementPipelineTests: XCTestCase {
    let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let date = Date(timeIntervalSince1970: 1_790_400_000)
    var user: ScaleUser { ScaleUser(deviceID: id, accountID: "12345", profileID: 1, userType: 1, age: 30, sex: 1, heightCm: 170) }
    func report(_ modify: (inout [String]) -> Void = { _ in }, delay: TimeInterval = 20) -> OnlineBodyReport {
        var fields = Array(repeating: "0", count: 32)
        fields[0] = "12345"; fields[1] = "1"; fields[2] = "1"; fields[3] = "700"
        fields[4] = "80"; fields[6] = "1790400000"; fields[7] = "200"; fields[14] = "242"
        fields[16] = "-19"; fields[30] = "5000"; fields[31] = "4500"
        modify(&fields)
        return OnlineBodyReport(deviceID: id, receivedAt: date.addingTimeInterval(delay), inBackground: true, fields: fields)
    }
    func testVerifiedMetricUnitsAndLeanMassCalculation() throws {
        let record = try OnlineMeasurement(report: report())
        let initial = record.metrics(for: user, mappingVerified: false)
        XCTAssertEqual(Set(initial.keys), [.weight,.bmi])
        XCTAssertEqual(initial[.bmi]!, 70/(1.7*1.7), accuracy: 0.0001)
        let verified = record.metrics(for: user, mappingVerified: true)
        XCTAssertEqual(verified[.bodyFat], 0.2) // HealthKit percentage is a fraction.
        XCTAssertEqual(verified[.heartRate], 80)
        XCTAssertEqual(verified[.leanMass], 56)
        XCTAssertEqual(verified[.weight], 70)
    }
    func testWrongPersonGuestUnboundAndClockCannotExport() throws {
        for change: (inout [String]) -> Void in [{ $0[0] = "98765" }, { $0[1] = "2" }, { $0[2] = "3" }, { $0[0] = "0"; $0[1] = "0" }] {
            XCTAssertTrue(try OnlineMeasurement(report: report(change)).metrics(for: user, mappingVerified: true).isEmpty)
        }
        XCTAssertTrue(try OnlineMeasurement(report: report()).metrics(for: nil, mappingVerified: true).isEmpty)
        XCTAssertTrue(try OnlineMeasurement(report: report(delay: 301)).metrics(for: user, mappingVerified: true).isEmpty)
        let other = ScaleUser(deviceID: UUID(), accountID: "12345", profileID: 1, userType: 1, age: 30, sex: 1, heightCm: 170)
        XCTAssertTrue(try OnlineMeasurement(report: report()).metrics(for: other, mappingVerified: true).isEmpty)
    }
    func testDuplicateAcrossRelaunchAndCorrectionPreservesStableSyncIdentity() throws {
        var journal = MeasurementJournal()
        XCTAssertTrue(try journal.ingest(report()))
        let original = journal.records[0]
        journal.records[0].exportedVersions["weight"] = 1
        journal = try JSONDecoder().decode(MeasurementJournal.self, from: JSONEncoder().encode(journal))
        XCTAssertFalse(try journal.ingest(report(delay: 40)))
        XCTAssertEqual(journal.records.count, 1)
        XCTAssertTrue(try journal.ingest(report { $0[4] = "81" }))
        XCTAssertEqual(journal.records[0].id, original.id)
        XCTAssertEqual(journal.records[0].revision, 2)
        XCTAssertEqual(journal.records[0].exportedVersions["weight"], 1)
        XCTAssertNotNil(journal.records[0].pendingMetrics(for: user, mappingVerified: true)[.weight])
        XCTAssertTrue(try journal.ingest(report { $0[6] = "1790400030" }))
        XCTAssertEqual(journal.records.count, 2) // Same weight in a new measurement is not a duplicate.
    }
    func testChangedShapeAndMissingBodyValuesOnlyAllowReliableMetrics() throws {
        for change: (inout [String]) -> Void in [{ $0[14] = "0" }, { $0[14] = "999" }] {
            let record = try OnlineMeasurement(report: report(change))
            XCTAssertEqual(Set(record.metrics(for: user, mappingVerified: true).keys), [.weight,.bmi])
        }
        let partial = try OnlineMeasurement(report: report { $0[4] = "0"; $0[7] = "0" })
        XCTAssertEqual(Set(partial.metrics(for: user, mappingVerified: true).keys), [.weight,.bmi])
        XCTAssertThrowsError(try OnlineMeasurement(report: report { $0.removeLast() }))
        XCTAssertThrowsError(try OnlineMeasurement(report: report { $0[3] = "-1" }))
    }
    func testExportLedgerAllowsPreviouslyUnverifiedMetricsLater() throws {
        var record = try OnlineMeasurement(report: report())
        record.exportedVersions = ["weight":1,"bmi":1]
        XCTAssertTrue(record.pendingMetrics(for: user, mappingVerified: false).isEmpty)
        XCTAssertEqual(Set(record.pendingMetrics(for: user, mappingVerified: true).keys), [.bodyFat,.leanMass,.heartRate])
    }
}

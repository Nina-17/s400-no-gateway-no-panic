import Foundation
import CryptoKit

struct ScaleUser: Codable, Equatable, Identifiable {
    let deviceID: UUID
    let accountID: String
    let profileID, userType, age, sex, heightCm: Int
    var id: String { "\(deviceID.uuidString)|\(accountID)|\(profileID)|\(userType)" }
    var summary: String { "用户 \(profileID) · \(heightCm) cm · \(age) 岁 · \(sex == 1 ? "男" : "女")" }
}

extension OnlineProfile {
    func users() throws -> [ScaleUser] {
        try Self.validate(syncTemplate)
        guard let object = try JSONSerialization.jsonObject(with: syncTemplate.suffix(from: 36)) as? [String: Any],
              let mid = object["mid"] as? String, let list = object["ud"] as? [[String: Any]] else { throw ScaleProtocolError.schema }
        return try list.map { user in
            guard let uid = user["uid"] as? Int, (1...255).contains(uid),
                  let type = user["ut"] as? Int, (1...2).contains(type),
                  let age = user["age"] as? Int, (1...130).contains(age),
                  let sex = user["sex"] as? Int, (1...2).contains(sex),
                  let height = user["hi"] as? Int, (20...250).contains(height) else { throw ScaleProtocolError.schema }
            return ScaleUser(deviceID: deviceID, accountID: mid, profileID: uid, userType: type,
                             age: age, sex: sex, heightCm: height)
        }
    }
}

enum HealthMetric: String, Codable, CaseIterable {
    case weight, bmi, bodyFat, leanMass, heartRate
    var title: String {
        switch self {
        case .weight: return "体重"
        case .bmi: return "BMI"
        case .bodyFat: return "体脂率"
        case .leanMass: return "去脂体重"
        case .heartRate: return "心率"
        }
    }
}

struct OnlineMeasurement: Codable, Equatable, Identifiable {
    let id: String
    let deviceID: UUID
    let accountID: String
    let profileID, userType: Int
    let measuredAt, receivedAt: Date
    let inBackground: Bool
    let weightKg: Double
    let fields: [String]
    var revision: Int = 1
    var exportedVersions: [String: Int] = [:]
    var exportError: String?

    init(report: OnlineBodyReport) throws {
        let f = report.fields
        guard f.count == 32, f.allSatisfy({ $0.count <= 20 && Int64($0) != nil }),
              let mid = UInt64(f[0]), mid <= 999_999_999_999_999,
              let uid = Int(f[1]), (0...255).contains(uid),
              let type = Int(f[2]), (0...3).contains(type),
              let weight = Int(f[3]), (10...3000).contains(weight),
              let timestamp = Int64(f[6]), (1_577_836_800...4_102_444_800).contains(timestamp) else {
            throw ScaleProtocolError.schema
        }
        deviceID = report.deviceID; accountID = String(mid); profileID = uid; userType = type
        measuredAt = Date(timeIntervalSince1970: Double(timestamp)); receivedAt = report.receivedAt
        inBackground = report.inBackground; weightKg = Double(weight)/10; fields = f
        let identity = "s400-online-v1|\(deviceID.uuidString)|\(accountID)|\(uid)|\(type)|\(timestamp)"
        id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var timeNeedsReview: Bool { abs(measuredAt.timeIntervalSince(receivedAt)) > 300 }
    func belongs(to user: ScaleUser?) -> Bool {
        guard let user else { return false }
        return deviceID == user.deviceID && accountID == user.accountID && profileID == user.profileID && userType == user.userType
    }
    // These two fields remain candidates until a matching displayed measurement is confirmed.
    var candidateBodyFatPercent: Double? {
        guard let raw = Int(fields[7]), (1...1000).contains(raw) else { return nil }
        return Double(raw)/10
    }
    var candidateHeartRate: Double? {
        guard let raw = Int(fields[4]), (30...250).contains(raw) else { return nil }
        return Double(raw)
    }
    func metrics(for user: ScaleUser?, mappingVerified: Bool) -> [HealthMetric: Double] {
        guard belongs(to: user), !timeNeedsReview, let user else { return [:] }
        let height = Double(user.heightCm)/100
        var metrics: [HealthMetric: Double] = [.weight: weightKg, .bmi: weightKg/(height*height)]
        // Cross-check the observed BMI position to reject a changed body-data schema.
        let reportedBMI = Double(fields[14]).map { $0/10 }
        let shapeMatches = reportedBMI.map { abs($0 - metrics[.bmi]!) <= 0.15 } ?? false
        if mappingVerified && shapeMatches {
            if let fat = candidateBodyFatPercent {
                metrics[.bodyFat] = fat/100
                metrics[.leanMass] = weightKg*(1-fat/100)
            }
            if let rate = candidateHeartRate { metrics[.heartRate] = rate }
        }
        return metrics
    }
    func pendingMetrics(for user: ScaleUser?, mappingVerified: Bool) -> [HealthMetric: Double] {
        metrics(for: user, mappingVerified: mappingVerified).filter { (exportedVersions[$0.key.rawValue] ?? 0) < revision }
    }
}

struct MeasurementJournal: Codable {
    var records: [OnlineMeasurement] = []
    var selectedUser: ScaleUser?
    var verifiedMappingDeviceID: UUID?
    var automaticHealthExport = false

    var mappingVerified: Bool { selectedUser != nil && verifiedMappingDeviceID == selectedUser?.deviceID }
    /// Same device/user/timestamp is one measurement. A correction replaces it with a higher sync version.
    @discardableResult mutating func ingest(_ report: OnlineBodyReport) throws -> Bool {
        var record = try OnlineMeasurement(report: report)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            let previous = records[index]
            guard previous.fields != record.fields else { return false }
            record.revision = previous.revision+1
            record.exportedVersions = previous.exportedVersions
            records[index] = record
        } else { records.append(record) }
        records.sort { $0.measuredAt > $1.measuredAt }
        return true
    }
}

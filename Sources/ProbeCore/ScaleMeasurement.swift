import Foundation
import CryptoKit

struct ScaleMeasurement: Codable, Equatable, Identifiable {
    let id: String
    let deviceID: UUID
    let receivedAt: Date
    let deviceTime: Date
    let profileID: Int
    let weightKg: Double
    let impedance: Double
    let lowFrequencyImpedance: Double
    let inBackground: Bool
    let reportedFlag4: Int?
    // Protocol shape is provisional until a real S400 sample is checked.
    let schema: String
    var timeNeedsReview: Bool { abs(deviceTime.timeIntervalSince(receivedAt)) > 86_400 }
}

enum ScalePayload {
    case live(weightKg: Double, stable: Bool)
    case candidate(ScaleMeasurement)
    case unsupported(ScalePacketInspection)

    static func parse(_ data: Data, deviceID: UUID, receivedAt: Date, inBackground: Bool) -> ScalePayload {
        let inspection = ScalePacketInspection.inspect(data)
        guard inspection.issues.isEmpty, let fields = inspection.numericFields else { return .unsupported(inspection) }
        let values = fields.compactMap(Int.init)
        if values.count == 2, (0...3000).contains(values[0]), (0...1).contains(values[1]) {
            return .live(weightKg: Double(values[0]) / 10, stable: values[1] == 1)
        }
        // Upstream accepts >=8 fields; intentionally require its documented 32-field final.
        guard values.count == 32 else { return .unsupported(inspection) }
        let identity = "\(deviceID.uuidString)|\(values[2])|\(values[6])|\(values[3])|\(values[30])|\(values[31])"
        let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return .candidate(ScaleMeasurement(id: id, deviceID: deviceID, receivedAt: receivedAt,
            deviceTime: Date(timeIntervalSince1970: Double(values[6])), profileID: values[2],
            weightKg: Double(values[3]) / 10, impedance: Double(values[30]) / 10,
            lowFrequencyImpedance: Double(values[31]) / 10, inBackground: inBackground,
            reportedFlag4: values[4], schema: "s400-csv32-candidate-v2"))
    }
}

/// Bounded diagnosis of authenticated measurement CSV only. Never pass login data
/// here. Numeric fields are kept in a separate protected file, not event exports.
struct ScalePacketInspection: Codable, Equatable {
    let byteCount: Int
    let fieldCount: Int
    let issues: [String]
    let numericFields: [String]?

    var explanation: String {
        if issues.contains("profile_out_of_range") { return "设备的用户编号与预期范围不符，已保留待核对" }
        if issues.contains("timestamp_out_of_range") { return "设备的时间字段与预期不符，已保留待核对" }
        if issues.contains("unknown_flag4") { return "收到未识别的状态字段，已保留待核对" }
        return "收到 \(fieldCount) 字段数据，部分字段与预期不符，已保留诊断"
    }

    static func inspect(_ data: Data) -> Self {
        guard data.count <= 4096, let marker = data.firstIndex(of: 0xa0),
              let text = String(data: data.suffix(from: data.index(after: marker)), encoding: .ascii) else {
            return Self(byteCount: data.count, fieldCount: 0, issues: ["no_ascii_csv"], numericFields: nil)
        }
        let fields = text.trimmingCharacters(in: CharacterSet(charactersIn: "\0 \r\n"))
            .split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count <= 64 else {
            return Self(byteCount: data.count, fieldCount: fields.count, issues: ["field_count"], numericFields: nil)
        }
        // Permit signed numeric text in diagnostic storage, but don't silently
        // accept a negative sentinel as an owned profile or valid measurement.
        let safeFields = fields.allSatisfy { field in
            let digits = field.first == "-" ? field.dropFirst() : field[...]
            return field.count <= 20 && !digits.isEmpty && digits.utf8.allSatisfy { (48...57).contains($0) }
        } ? fields : nil
        var issues: [String] = []
        let values: [Int?] = fields.map { field in
            guard !field.isEmpty, field.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(field)
        }
        for (index, value) in values.enumerated() where value == nil { issues.append("non_unsigned_integer_\(index)") }
        if fields.count == 2 {
            if values[0].map({ !(0...3000).contains($0) }) ?? true { issues.append("live_weight") }
            if values[1].map({ !(0...1).contains($0) }) ?? true { issues.append("live_stable") }
        } else if fields.count == 32 {
            if values[0] != 0 || values[1] != 0 { issues.append("prefix_mismatch") }
            if values[4].map({ !(0...1).contains($0) }) ?? true { issues.append("unknown_flag4") }
            if values[3].map({ !(10...3000).contains($0) }) ?? true { issues.append("weight_out_of_range") }
            if values[2].map({ !(0...65535).contains($0) }) ?? true { issues.append("profile_out_of_range") }
            if values[6].map({ !(1_577_836_800...4_102_444_800).contains($0) }) ?? true { issues.append("timestamp_out_of_range") }
            if values[30].map({ !(0...30000).contains($0) }) ?? true { issues.append("impedance_out_of_range") }
            if values[31].map({ !(0...30000).contains($0) }) ?? true { issues.append("low_impedance_out_of_range") }
        } else { issues.append("field_count") }
        return Self(byteCount: data.count, fieldCount: fields.count, issues: issues, numericFields: safeFields)
    }
}

struct UnrecognizedMeasurement: Codable {
    let receivedAt: Date
    let deviceID: UUID
    let inBackground: Bool
    let inspection: ScalePacketInspection
}

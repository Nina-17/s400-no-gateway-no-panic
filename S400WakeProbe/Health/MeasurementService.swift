import Combine
import Foundation
import HealthKit
import UIKit

/// All state changes run on the Bluetooth/main queue; HealthKit callbacks hop back to it.
final class MeasurementService: ObservableObject {
    @Published private(set) var journal = MeasurementJournal()
    @Published private(set) var users: [ScaleUser] = []
    @Published private(set) var issue: String?
    @Published private(set) var healthStatus = "尚未开启 Apple 健康同步"
    @Published private(set) var syncing = false
    @Published private(set) var authorizedMetrics = Set<HealthMetric>()
    private var deviceID: UUID?
    private var currentProfile: OnlineProfile?
    private var loaded = false
    private var storage: ProbeStorage?
    private let health = HKHealthStore()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var activeExportID: UUID?
    var event: ((String, [String: String]) -> Void)?
    var records: [OnlineMeasurement] { journal.records.filter { $0.deviceID == deviceID } }
    var selectedUser: ScaleUser? { journal.selectedUser.flatMap { users.contains($0) ? $0 : nil } }
    var mappingVerified: Bool { selectedUser != nil && journal.mappingVerified }
    var missingPermissions: [HealthMetric] {
        let expected: [HealthMetric] = mappingVerified ? HealthMetric.allCases : [.weight, .bmi]
        return expected.filter { !authorizedMetrics.contains($0) }
    }
    var syncedWeightCount: Int {
        records.filter { $0.belongs(to: selectedUser) && $0.exportedVersions["weight"] == $0.revision }.count
    }
    var hasUndecidedPermissions: Bool {
        HKHealthStore.isHealthDataAvailable() && HealthMetric.allCases.contains {
            health.authorizationStatus(for: type($0)) == .notDetermined
        }
    }
    func permissionLabel(for metric: HealthMetric) -> String {
        guard HKHealthStore.isHealthDataAvailable() else { return "不可用" }
        switch health.authorizationStatus(for: type(metric)) {
        case .sharingAuthorized: return "已允许"
        case .sharingDenied: return "未允许"
        case .notDetermined: return "尚未选择"
        @unknown default: return "状态未知"
        }
    }
    func checkHealthPermissions() { refreshPermissions() }
    func requestUndecidedPermissions() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let types = Set(HealthMetric.allCases.filter {
            health.authorizationStatus(for: type($0)) == .notDetermined
        }.map { type($0) as HKSampleType })
        guard !types.isEmpty else { return }
        health.requestAuthorization(toShare: types, read: []) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshPermissions() }
        }
    }

    func configure(profile: OnlineProfile?) {
        currentProfile = profile
        deviceID = profile?.deviceID
        users = (try? profile?.users()) ?? []
        do {
            if !loaded {
                let store = try ProbeStorage(); storage = store
                let url = store.directory.appendingPathComponent("measurement-journal.json")
                if FileManager.default.fileExists(atPath: url.path) {
                    journal = try JSONDecoder().decode(MeasurementJournal.self, from: Data(contentsOf: url))
                }
                // Original capture history is preserved. Import valid reports idempotently.
                let raw = store.directory.appendingPathComponent("online-body-reports.json")
                if FileManager.default.fileExists(atPath: raw.path) {
                    let reports = try JSONDecoder().decode([OnlineBodyReport].self, from: Data(contentsOf: raw))
                    for report in reports.reversed() { _ = try? journal.ingest(report) }
                }
                try persist(); loaded = true
            }
            issue = nil
            refresh()
        } catch {
            loaded = false
            issue = "记录存储暂不可用，已保留原文件"
            event?("measurement_journal_load_failed", [:])
        }
    }

    func ingest(_ report: OnlineBodyReport) {
        guard loaded else { issue = "存储未就绪，请解锁后打开 App 重试"; return }
        do {
            var next = journal
            let changed = try next.ingest(report)
            if changed { try persist(next); journal = next }
            event?(changed ? "measurement_record_saved" : "measurement_duplicate_ignored", [:])
            issue = nil
            syncPending()
        } catch {
            issue = "这条结果尚未能加入称重记录，原报文仍保留"
            event?("measurement_record_rejected", ["reason": (error as? ScaleProtocolError)?.rawValue ?? "storage"])
        }
    }

    func selectUser(_ user: ScaleUser) {
        guard users.contains(user), loaded else { return }
        var next = journal; next.selectedUser = user
        next.automaticHealthExport = false
        if commit(next) { healthStatus = "已选择本人资料，等待健康授权" }
    }

    func verifyMapping(record: OnlineMeasurement, bodyFat: Double, heartRate: Int) throws {
        guard record.belongs(to: selectedUser), !record.timeNeedsReview,
              record.metrics(for: selectedUser, mappingVerified: true)[.bodyFat] != nil,
              let expectedFat = record.candidateBodyFatPercent, let expectedHeart = record.candidateHeartRate,
              abs(bodyFat-expectedFat) < 0.05, Double(heartRate) == expectedHeart else { throw ScaleProtocolError.schema }
        var next = journal; next.verifiedMappingDeviceID = record.deviceID
        try persist(next); journal = next
        event?("body_mapping_confirmed_on_device", [:])
        syncPending()
    }

    func requestHealthAuthorization() {
        guard loaded, selectedUser != nil else { healthStatus = "请先确认本人的米家资料"; return }
        guard HKHealthStore.isHealthDataAvailable() else { healthStatus = "此设备无法使用 Apple 健康"; return }
        let types = Set(HealthMetric.allCases.map { type($0) as HKSampleType })
        health.requestAuthorization(toShare: types, read: []) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard success, error == nil else {
                    self.healthStatus = "健康授权未完成，可稍后重试"
                    self.event?("health_authorization_failed", [:]); return
                }
                self.refreshPermissions()
                guard self.canWrite(.weight) else { self.healthStatus = "体重写入未获授权，请在健康中开启"; return }
                var next = self.journal; next.automaticHealthExport = true
                if self.commit(next) { self.refresh() }
            }
        }
    }

    func pauseHealthExport() {
        var next = journal; next.automaticHealthExport = false
        if commit(next) { healthStatus = "健康同步已暂停，称重继续保存在本机" }
    }

    func refresh() {
        if !loaded { configure(profile: currentProfile); return }
        refreshPermissions()
        if journal.automaticHealthExport {
            healthStatus = canWrite(.weight) ? "已开启自动同步" : "体重权限已关闭，结果保留在本机"
            syncPending()
        }
    }

    private func refreshPermissions() {
        // A denial can change notDetermined -> sharingDenied without changing the
        // authorized set; the permission sheet still needs to refresh its labels.
        objectWillChange.send()
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let current = Set(HealthMetric.allCases.filter { canWrite($0) })
        guard current != authorizedMetrics else { return }
        authorizedMetrics = current
        event?("health_write_permissions_changed", ["authorized": current.map(\.rawValue).sorted().joined(separator: ","),
            "heartRateStatus": String(health.authorizationStatus(for: type(.heartRate)).rawValue)])
    }

    private func type(_ metric: HealthMetric) -> HKQuantityType {
        let identifier: HKQuantityTypeIdentifier
        switch metric {
        case .weight: identifier = .bodyMass
        case .bmi: identifier = .bodyMassIndex
        case .bodyFat: identifier = .bodyFatPercentage
        case .leanMass: identifier = .leanBodyMass
        case .heartRate: identifier = .heartRate
        }
        return HKObjectType.quantityType(forIdentifier: identifier)!
    }
    private func canWrite(_ metric: HealthMetric) -> Bool { health.authorizationStatus(for: type(metric)) == .sharingAuthorized }

    func syncPending() {
        guard loaded, journal.automaticHealthExport, !syncing, let user = selectedUser else { return }
        guard let record = records.first(where: { record in
            record.pendingMetrics(for: user, mappingVerified: mappingVerified).keys.contains { canWrite($0) }
        }) else { return }
        let values = record.pendingMetrics(for: user, mappingVerified: mappingVerified).filter { canWrite($0.key) }
        let samples = values.map { metric, value -> HKQuantitySample in
            let unit: HKUnit
            switch metric {
            case .weight, .leanMass: unit = .gramUnit(with: .kilo)
            case .bmi: unit = .count()
            case .bodyFat: unit = .percent()
            case .heartRate: unit = .count().unitDivided(by: .minute())
            }
            return HKQuantitySample(type: type(metric), quantity: HKQuantity(unit: unit, doubleValue: value),
                start: record.measuredAt, end: record.measuredAt,
                metadata: [HKMetadataKeySyncIdentifier: "s400.\(record.id).\(metric.rawValue)",
                           HKMetadataKeySyncVersion: record.revision,
                           HKMetadataKeyWasUserEntered: false,
                           "S400Source": metric == .leanMass ? "derived-from-verified-body-fat" :
                             (metric == .bmi ? "derived-from-weight-and-profile-height" : "authenticated-online")])
        }
        let exportID = UUID()
        activeExportID = exportID
        syncing = true; healthStatus = "正在同步 Apple 健康…"
        beginBackgroundTask(exportID: exportID)
        health.save(samples) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self, self.activeExportID == exportID else { return }
                defer { self.activeExportID = nil; self.syncing = false; self.endBackgroundTask() }
                var next = self.journal
                guard let index = next.records.firstIndex(where: { $0.id == record.id }) else { return }
                if success && error == nil {
                    for metric in values.keys {
                        next.records[index].exportedVersions[metric.rawValue] = record.revision
                    }
                    next.records[index].exportError = nil
                    if self.commit(next) {
                        self.healthStatus = "已同步 Apple 健康"
                        self.event?("health_samples_saved", ["sampleCount": String(samples.count)])
                        DispatchQueue.main.async { [weak self] in self?.syncPending() }
                    }
            } else {
                    // Keep a durable pending item. A later Bluetooth callback or unlock retries it.
                    next.records[index].exportError = "健康写入暂未成功，待重试"
                    _ = self.commit(next)
                    self.healthStatus = "健康暂不可写，结果已保存，稍后自动重试"
                    self.event?("health_samples_deferred", ["code": String((error as NSError?)?.code ?? -1)])
                }
            }
        }
    }

    private func beginBackgroundTask(exportID: UUID) {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "S400HealthSave") { [weak self] in
            guard let self, self.activeExportID == exportID else { return }
            self.activeExportID = nil; self.syncing = false
            self.healthStatus = "本次同步时间已到，结果保留，稍后重试"
            self.endBackgroundTask()
            self.event?("health_save_background_time_expired", [:])
        }
    }
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
    }
    private func persist(_ value: MeasurementJournal? = nil) throws {
        guard let storage else { throw CocoaError(.fileWriteUnknown) }
        try JSONEncoder().encode(value ?? journal).write(to: storage.directory.appendingPathComponent("measurement-journal.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    @discardableResult private func commit(_ next: MeasurementJournal) -> Bool {
        do { try persist(next); journal = next; issue = nil; return true }
        catch { issue = "记录状态保存失败，待重试"; return false }
    }
}

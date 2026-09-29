import Combine
import CoreBluetooth
import Security
import UIKit

/// Main-queue adapter. Deadlines limit an active exchange; they never keep iOS awake.
final class ScaleSessionController: ObservableObject {
    let pipeline = MeasurementService()
    @Published private(set) var status = "配置 token 后可读取称重"
    @Published private(set) var hasToken = false
    @Published private(set) var credentialUnavailable = false
    @Published private(set) var authenticated = false
    @Published private(set) var liveWeight: Double?
    @Published private(set) var liveStable = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasOnlineProfile = false
    @Published private(set) var onlineReady = false
    private var bodyReportReceivedAt: Date?
    private var online: OnlineInitialization?
    private var didLogLive = false
    var event: ((String, [String: String]) -> Void)?
    var reconnect: (() -> Void)?
    var release: (() -> Void)?
    private var targetID: UUID?
    private var peripheral: CBPeripheral?
    private var characteristics: [ScaleChannel: CBCharacteristic] = [:]
    private var pendingSubscriptions = Set<ScaleChannel>()
    private var session: MiHomeSession?
    private var queue: [ScaleWrite] = []
    private var deadlineWork: DispatchWorkItem?
    private var subscriptionDeadline: Date?
    private var loginDeadline: Date?
    private var writeDeadline: Date?
    private var failureKey: String { "s400.authFailure.\(targetID?.uuidString ?? "none")" }
    func configure(_ id: UUID?) {
        guard targetID != id else { return }
        reset()
        targetID = id
        refreshCredentialStatus()
        hasOnlineProfile = (try? loadOnlineProfile()) != nil
        pipeline.event = { [weak self] name, details in self?.event?(name, details) }
        pipeline.configure(profile: try? loadOnlineProfile())
    }

    @discardableResult
    func retryCredentialReadIfNeeded() -> Bool {
        guard !hasToken else { return false }
        refreshCredentialStatus()
        return hasToken
    }

    private func refreshCredentialStatus() {
        guard let id = targetID else { hasToken = false; credentialUnavailable = false; return }
        do {
            hasToken = try ScaleCredentials.read(for: id) != nil
            credentialUnavailable = false
            errorMessage = UserDefaults.standard.string(forKey: failureKey)
            status = errorMessage != nil ? "称重读取已暂停" : (hasToken ? "等待连接后登录" : "尚未配置登录 token")
        } catch {
            hasToken = false
            credentialUnavailable = true
            errorMessage = "钥匙串暂不可用，请解锁后重试"
            status = "登录凭据暂不可读"
        }
    }

    func saveToken(_ text: String) throws {
        guard let id = targetID else { throw ScaleProtocolError.tokenFormat }
        try ScaleCredentials.save(TokenFormat.parse(text), for: id)
        UserDefaults.standard.removeObject(forKey: failureKey)
        refreshCredentialStatus()
        reset()
        event?("credential_saved", [:])
        reconnect?()
    }

    func removeToken() throws {
        guard let id = targetID else { return }
        try ScaleCredentials.remove(for: id)
        UserDefaults.standard.removeObject(forKey: failureKey)
        reset(); refreshCredentialStatus()
        event?("credential_removed", [:])
        release?()
    }

    func retry() {
        bodyReportReceivedAt = nil
        UserDefaults.standard.removeObject(forKey: failureKey)
        reset(); refreshCredentialStatus()
        reconnect?()
    }

    func reset() {
        deadlineWork?.cancel(); deadlineWork = nil
        subscriptionDeadline = nil; loginDeadline = nil; writeDeadline = nil
        session = nil; queue = []; characteristics = [:]; pendingSubscriptions = []
        online = nil; onlineReady = false
        peripheral = nil; authenticated = false; liveWeight = nil; liveStable = false
        bodyReportReceivedAt = nil
        didLogLive = false
        status = errorMessage != nil ? "称重读取已暂停" : (hasToken ? "等待连接后登录" : "尚未配置登录 token")
    }

    func begin(_ p: CBPeripheral) {
        guard p.identifier == targetID, p.state == .connected, peripheral == nil else { return }
        guard UserDefaults.standard.string(forKey: failureKey) == nil else { return }
        do {
            guard try ScaleCredentials.read(for: p.identifier) != nil else { hasToken = false; return }
            hasToken = true
        } catch { markCredentialUnavailable(); return }
        do { online = OnlineInitialization(profile: try loadOnlineProfile()) }
        catch { fail("米家资料尚未导入或无法校验，请先完成资料导入", code: "online_profile"); return }
        guard let service = p.services?.first(where: { $0.uuid == CBUUID(string: "FE95") }),
              let discovered = service.characteristics else { return }
        var found: [ScaleChannel: CBCharacteristic] = [:]
        for channel in ScaleChannel.allCases {
            guard let c = discovered.first(where: { $0.uuid == CBUUID(string: channel.rawValue) }),
                  c.properties.contains(.writeWithoutResponse),
                  c.properties.contains(.notify) || c.properties.contains(.indicate) else {
                fail("体脂秤缺少所需的通信通道", code: "missing_characteristic"); return
            }
            found[channel] = c
        }
        peripheral = p; characteristics = found
        pendingSubscriptions = Set(ScaleChannel.allCases)
        subscriptionDeadline = Date().addingTimeInterval(10)
        status = "正在订阅称重通道"
        event?("measurement_subscriptions_requested", [:])
        for (channel, c) in found {
            if c.isNotifying {
                pendingSubscriptions.remove(channel)
            } else { p.setNotifyValue(true, for: c) }
        }
        startLoginIfReady()
        scheduleDeadline()
    }

    func subscription(_ p: CBPeripheral, _ c: CBCharacteristic, error: Error?) {
        guard p === peripheral, let channel = channel(for: c) else { return }
        guard error == nil, c.isNotifying else { fail("订阅称重通知失败，请重试", code: "subscribe"); return }
        guard checkDeadlines() else { return }
        pendingSubscriptions.remove(channel)
        startLoginIfReady()
    }

    private func startLoginIfReady() {
        guard pendingSubscriptions.isEmpty, session == nil, let p = peripheral else { return }
        do {
            guard let token = try ScaleCredentials.read(for: p.identifier) else { throw ScaleProtocolError.tokenFormat }
            var random = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
                throw ScaleProtocolError.randomLength
            }
            let s = try MiHomeSession(token: token, random: Data(random))
            session = s; subscriptionDeadline = nil; loginDeadline = Date().addingTimeInterval(60)
            status = "正在验证体脂秤身份"
            event?("login_started", [:])
            try apply(s.start(at: Date()))
        } catch let error as NSError where error.domain == "ScaleKeychain" {
            markCredentialUnavailable()
        } catch { handle(error) }
    }

    private func markCredentialUnavailable() {
        hasToken = false
        credentialUnavailable = true
        errorMessage = "钥匙串暂不可用，请解锁后重试"
        status = "登录凭据暂不可读"
        event?("keychain_temporarily_unavailable", [:])
    }

    func notification(_ p: CBPeripheral, _ c: CBCharacteristic, error: Error?) {
        guard p === peripheral, let channel = channel(for: c), let s = session else { return }
        guard error == nil, let data = c.value else { fail("蓝牙通知读取失败", code: "notification"); return }
        guard checkDeadlines() else { return }
        do {
            let previousStage = s.stage
            let effects = try s.receive(data, on: channel, at: Date())
            if previousStage != s.stage { event?("login_stage_changed", ["stage": s.stage.rawValue]) }
            try apply(effects)
        }
        catch { handle(error) }
    }

    func readyToWrite(_ p: CBPeripheral) {
        guard p === peripheral, checkDeadlines() else { return }
        drain()
    }

    private func channel(for c: CBCharacteristic) -> ScaleChannel? {
        characteristics.first(where: { $0.value === c })?.key
    }

    private func apply(_ effects: [MiHomeSession.Effect]) throws {
        for effect in effects {
            switch effect {
            case .write(let write):
                guard queue.count < 32 else { throw ScaleProtocolError.framing }
                if queue.isEmpty { writeDeadline = Date().addingTimeInterval(8) }
                queue.append(write)
            case .authenticated:
                authenticated = true; errorMessage = nil; loginDeadline = nil
                status = "已登录，请赤脚上秤完成称重"
                event?("login_succeeded", [:])
                if let online {
                    status = "正在同步米家用户资料与测量设置"
                    try sendOnline(online.start(at: Date()))
                    event?("online_initialization_started", [:])
                }
            case .applicationSent:
                guard let online else { throw ScaleProtocolError.framing }
                try sendOnline(online.acknowledge(at: Date()))
                updateOnlineReady()
            case .payload(let data):
                guard let id = targetID else { return }
                guard let online else { throw ScaleProtocolError.framing }
                let message = try OnlineMessage.parse(data)
                switch message {
                    case .hello, .syncResponse:
                        try sendOnline(online.receive(message, at: Date()))
                        updateOnlineReady()
                    case .live(let weight, let phase):
                        guard onlineReady else { throw ScaleProtocolError.rejected }
                        liveWeight = weight; liveStable = phase > 0
                        if bodyReportReceivedAt == nil {
                            status = phase == 2 ? "测量进行中，请继续站立等待心率" : (phase == 1 ? "体重已稳定，请继续站立" : "正在称重…")
                        }
                        if !didLogLive { didLogLive = true; event?("online_live_received", [:]) }
                    case .body(let fields):
                        guard onlineReady else { throw ScaleProtocolError.rejected }
                        let report = OnlineBodyReport(deviceID: id, receivedAt: Date(),
                            inBackground: UIApplication.shared.applicationState == .background, fields: fields)
                        try saveOnline(report)
                        pipeline.ingest(report)
                        bodyReportReceivedAt = report.receivedAt
                        status = "已收到体成分结果 · 保持连接"
                        event?("online_body_report_saved", ["fieldCount": String(fields.count), "background": String(report.inBackground)])
                }
            }
        }
        drain(); scheduleDeadline()
    }

    private func drain() {
        guard let p = peripheral, p.state == .connected else { return }
        while !queue.isEmpty && p.canSendWriteWithoutResponse {
            let write = queue.removeFirst()
            guard let c = characteristics[write.channel], write.data.count <= p.maximumWriteValueLength(for: .withoutResponse) else {
                fail("蓝牙写入长度或通道异常", code: "write"); return
            }
            p.writeValue(write.data, for: c, type: .withoutResponse)
        }
        if queue.isEmpty { writeDeadline = nil }
    }

    private func loadOnlineProfile() throws -> OnlineProfile {
        let url = try ProbeStorage().directory.appendingPathComponent("online-profile.json")
        let profile = try JSONDecoder().decode(OnlineProfile.self, from: Data(contentsOf: url))
        guard profile.deviceID == targetID else { throw ScaleProtocolError.schema }
        try OnlineProfile.validate(profile.syncTemplate)
        return profile
    }

    private func sendOnline(_ payload: Data?) throws {
        guard let payload, let session else { return }
        try apply(session.sendApplication(payload, at: Date()))
    }

    private func updateOnlineReady() {
        guard !onlineReady, online?.stage == .ready else { return }
        onlineReady = true
        status = "在线初始化成功，可以赤脚上秤"
        event?("online_initialization_succeeded", [:])
    }

    private func saveOnline(_ report: OnlineBodyReport) throws {
        let url = try ProbeStorage().directory.appendingPathComponent("online-body-reports.json")
        var reports: [OnlineBodyReport] = []
        if FileManager.default.fileExists(atPath: url.path) {
            reports = try JSONDecoder().decode([OnlineBodyReport].self, from: Data(contentsOf: url))
        }
        reports.insert(report, at: 0)
        try JSONEncoder().encode(Array(reports.prefix(20))).write(to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func checkDeadlines() -> Bool {
        let now = Date()
        do {
            if let d = subscriptionDeadline, now >= d { throw ScaleProtocolError.timeout }
            if let d = loginDeadline, now >= d { throw ScaleProtocolError.timeout }
            if let d = writeDeadline, now >= d { throw ScaleProtocolError.timeout }
            if let d = online?.deadline, now >= d { throw ScaleProtocolError.timeout }
            try session?.checkDeadline(at: now)
            return true
        } catch { handle(error); return false }
    }

    private func scheduleDeadline() {
        deadlineWork?.cancel(); deadlineWork = nil
        guard let deadline = [subscriptionDeadline, loginDeadline, writeDeadline, session?.deadline, online?.deadline].compactMap({ $0 }).min() else { return }
        let work = DispatchWorkItem { [weak self] in _ = self?.checkDeadlines() }
        deadlineWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, deadline.timeIntervalSinceNow), execute: work)
    }

    private func handle(_ error: Error) {
        if let protocolError = error as? ScaleProtocolError { fail(protocolError.message, code: protocolError.rawValue) }
        else { fail("称重处理或本地保存失败，请查看诊断后重试", code: "processing_or_storage") }
    }

    private func fail(_ message: String, code: String) {
        let stage = session?.stage.rawValue ?? "subscription_or_setup"
        UserDefaults.standard.set(message, forKey: failureKey)
        reset(); errorMessage = message; status = "称重读取已暂停"
        event?("measurement_session_failed", ["reason": code, "stage": stage])
        // Pause auth persistently rather than retry bad credentials on every reconnect.
        release?()
    }
}

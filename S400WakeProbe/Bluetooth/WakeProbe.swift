import Combine
@preconcurrency import CoreBluetooth
import OSLog
import UIKit

struct ScaleCandidate: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
    let identity: MiBeaconIdentity?
    let connectable: Bool?
}

/// All state, CoreBluetooth callbacks and disk operations run on the main queue.
/// The singleton is owned for the process lifetime, independently of any View.
final class WakeProbe: NSObject, ObservableObject {
    static let shared = WakeProbe()
    static var restorationID: String {
        "\(Bundle.main.bundleIdentifier ?? "org.example.s400nogateway").central.v1"
    }
    private static let serviceUUID = CBUUID(string: "FE95")

    @Published private(set) var configuration = ProbeConfiguration()
    @Published private(set) var candidates: [ScaleCandidate] = []
    @Published private(set) var status = "尚未选择体脂秤"
    @Published private(set) var bluetoothState = "未初始化"
    @Published private(set) var scanMode: String?
    @Published private(set) var logLines: [String] = []
    @Published private(set) var storageError: String?
    @Published private(set) var linkState: PeripheralLinkState?
    @Published private(set) var gattReady = false
    let reader = ScaleSessionController()
    private var readerRestartPending = false

    var connectionTitle: String {
        if configuration.target == nil { return "添加你的体脂秤" }
        if !configuration.isArmed { return "自动连接已暂停" }
        switch linkState {
        case .connected: return "体脂秤已连接"
        case .connecting: return "正在等待体脂秤"
        case .disconnecting: return "正在准备连接"
        default: return central?.state == .poweredOn ? "正在寻找体脂秤" : "等待蓝牙就绪"
        }
    }

    private var storage: ProbeStorage?
    private var configurationLoaded = false
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var inspectedPeripheral: UUID?
    private var pendingLoggedFor: UUID?
    private var onboardingRequested = false
    private var scanDeadline: DispatchWorkItem?
    private var lastActivity = "none"
    private let runID = UUID()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "org.example.s400nogateway", category: "Probe")

    private override init() {
        super.init()
        loadStorage()
        reader.event = { [weak self] name, details in self?.record(name, details: details) }
        reader.configure(configuration.target?.identifier)
        reader.reconnect = { [weak self] in
            guard let self else { return }
            if self.configuration.isArmed { self.restartMeasurementConnection() }
            else { self.arm() }
        }
        reader.release = { [weak self] in self?.stop() }
    }

    func launched(restorationIdentifiers: [String]) {
        record("process_launched", details: [
            "restorationIdentifiers": restorationIdentifiers.joined(separator: ","),
            "iOS": UIDevice.current.systemVersion,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        ])
        // Recreate the same manager during launch, before a SwiftUI screen exists.
        if configuration.isArmed || restorationIdentifiers.contains(Self.restorationID) {
            ensureCentral()
        }
    }

    func didEnterBackground() {
        var next = configuration
        next.lastBackgroundAt = Date()
        if configurationLoaded { _ = commit(next) }
        record("entered_background")
        // The one-time onboarding scan is foreground only. A pending connection
        // is deliberately NOT canceled when the UI disappears or the phone locks.
        if onboardingRequested {
            onboardingRequested = false
            stopScan()
            reconcile()
        }
    }

    func didBecomeActive() {
        reader.pipeline.refresh()
        let credentialRestored = reader.retryCredentialReadIfNeeded()
        record("became_active")
        // Avoid reporting time spent in an earlier background session as current.
        if configurationLoaded, configuration.lastBackgroundAt != nil {
            var next = configuration
            next.lastBackgroundAt = nil
            _ = commit(next)
        }
        if credentialRestored && linkState == .connected { restartMeasurementConnection() }
        else { reconcile() }
    }

    func protectedDataChanged(available: Bool) {
        if available { reader.pipeline.refresh() }
        if available && !configurationLoaded {
            loadStorage()
            if configurationLoaded { reader.configure(configuration.target?.identifier) }
        }
        let credentialRestored = available && reader.retryCredentialReadIfNeeded()
        record(available ? "protected_data_available" : "protected_data_unavailable")
        if available && configuration.isArmed {
            ensureCentral()
            if credentialRestored && linkState == .connected { restartMeasurementConnection() }
            else { reconcile() }
        }
    }

    func discover() {
        guard configurationLoaded, !configuration.isArmed,
              UIApplication.shared.applicationState == .active else { return }
        onboardingRequested = true
        candidates = []
        ensureCentral()
        reconcile()
    }

    func stopDiscovery() {
        onboardingRequested = false
        stopScan()
        status = "扫描已停止"
    }

    func select(_ candidate: ScaleCandidate) {
        guard !configuration.isArmed, peripherals[candidate.id] != nil else { return }
        var next = configuration
        next.target = ScaleTarget(identifier: candidate.id, name: candidate.name,
                                  advertisedMAC: candidate.identity?.advertisedMAC,
                                  productID: candidate.identity?.productID)
        guard commit(next) else { return }
        reader.configure(candidate.id)
        onboardingRequested = false
        stopScan()
        status = "已保存目标；开启自动连接即可"
        record("target_selected", peripheralID: candidate.id,
               details: ["productID": candidate.identity.map { String(format: "%04X", $0.productID) } ?? "unknown"])
    }

    func arm() {
        guard configurationLoaded, configuration.target != nil else { return }
        var next = configuration
        next.isArmed = true
        next.trialID = UUID()
        next.recentTerminations = []
        guard commit(next) else { return }
        onboardingRequested = false
        stopScan()
        record("trial_armed")
        ensureCentral()
        reconcile()
    }

    func stop() {
        reader.reset()
        var next = configuration
        next.isArmed = false
        _ = commit(next)
        onboardingRequested = false
        stopScan()
        cancelUnwantedConnections()
        status = storageError == nil ? "已停止等待" : "已停止；配置保存失败，请重试"
        record("monitoring_stopped")
    }

    func retryStorage() {
        loadStorage()
        if configurationLoaded {
            reader.configure(configuration.target?.identifier)
            record("storage_reloaded")
            if configuration.isArmed { ensureCentral(); reconcile() }
        }
    }

    func exportLog() -> URL? {
        do {
            guard let storage else { return nil }
            record("log_export_requested")
            return try storage.export()
        } catch {
            storageError = "日志导出失败：\(error.localizedDescription)"
            return nil
        }
    }

    private func loadStorage() {
        do {
            let disk = try ProbeStorage()
            let loaded = try disk.load()
            storage = disk
            configuration = loaded
            configurationLoaded = true
            logLines = try disk.recentLines()
            storageError = nil
            status = loaded.target == nil ? "请在前台扫描并选择自己的 S400" : "已载入目标秤"
        } catch {
            configurationLoaded = false
            storageError = "配置或日志不可用：\(error.localizedDescription)"
            status = "存储失败，暂停连接；解锁后重试"
        }
    }

    @discardableResult
    private func commit(_ next: ProbeConfiguration) -> Bool {
        do {
            guard configurationLoaded, let storage else { return false }
            try storage.save(next)
            configuration = next
            return true
        } catch {
            configuration.isArmed = false
            configurationLoaded = false
            storageError = "保存配置失败：\(error.localizedDescription)"
            status = "存储失败，暂停连接"
            stopScan()
            cancelUnwantedConnections()
            return false
        }
    }

    private func ensureCentral() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: Self.restorationID,
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
        record("central_created")
    }

    private func reconcile() {
        guard let central, central.state == .poweredOn else { return }
        cancelUnwantedConnections()
        guard configurationLoaded else { stopScan(); return }
        if onboardingRequested && UIApplication.shared.applicationState == .active {
            startOnboardingScan()
            return
        }
        guard configuration.isArmed, let target = configuration.target else {
            stopScan()
            return
        }
        let peripheral = peripherals[target.identifier]
            ?? central.retrievePeripherals(withIdentifiers: [target.identifier]).first
        guard let peripheral else {
            // Explicit service filtering is required for ordinary background scans.
            // This fallback may still miss S400 firmware advertisements: log it.
            if scanMode != "recovery" {
                stopScan()
                central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
                scanMode = "recovery"
                record("identifier_cache_miss_filtered_scan", peripheralID: target.identifier)
            }
            status = "设备缓存缺失，正在按 FE95 寻找原 UUID；找不到需前台重新选择"
            return
        }
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        stopScan()
        linkState = peripheral.state.linkState
        if readerRestartPending && peripheral.state != .disconnected {
            if peripheral.state != .disconnecting { central.cancelPeripheralConnection(peripheral) }
            return
        }
        readerRestartPending = false
        switch ConnectionPolicy.action(armed: configuration.isArmed, targetID: target.identifier,
                                        peripheralID: peripheral.identifier, poweredOn: true,
                                        state: peripheral.state.linkState) {
        case .connect:
            inspectedPeripheral = nil
            gattReady = false
            pendingLoggedFor = peripheral.identifier
            status = "等待 S400 出现（系统 pending connection）"
            lastActivity = "connect_requested"
            linkState = .connecting
            record("connect_requested", peripheralID: peripheral.identifier)
            // Do not impose a timeout or periodically cancel/reissue this request.
            central.connect(peripheral, options: nil)
        case .keepPending:
            status = "等待 S400 出现（保留现有连接请求）"
            if pendingLoggedFor != peripheral.identifier {
                pendingLoggedFor = peripheral.identifier
                record("pending_connection_preserved", peripheralID: peripheral.identifier)
            }
        case .inspectServices:
            inspectServices(peripheral)
        case .awaitDisconnect:
            status = "等待断开回调后重新挂起连接"
        case .cancel:
            central.cancelPeripheralConnection(peripheral)
        case .idle:
            break
        }
    }

    private func startOnboardingScan() {
        guard scanMode != "onboarding", let central else { return }
        stopScan()
        // Broad scanning is intentionally limited to 30 seconds in foreground:
        // some firmware includes FE95 only as service data, not in its UUID list.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanMode = "onboarding"
        status = "前台扫描 30 秒；轻踩唤醒秤，核对名称与 MAC 后选择"
        record("onboarding_scan_started")
        let deadline = DispatchWorkItem { [weak self] in self?.stopDiscovery() }
        scanDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: deadline)
    }

    private func stopScan() {
        scanDeadline?.cancel()
        scanDeadline = nil
        if central?.state == .poweredOn, central?.isScanning == true { central?.stopScan() }
        scanMode = nil
    }

    private func cancelUnwantedConnections() {
        guard let central, central.state == .poweredOn else { return }
        for peripheral in peripherals.values {
            if ConnectionPolicy.action(armed: configurationLoaded && configuration.isArmed,
                targetID: configuration.target?.identifier, peripheralID: peripheral.identifier,
                poweredOn: true, state: peripheral.state.linkState) == .cancel {
                central.cancelPeripheralConnection(peripheral)
            }
        }
    }

    private func inspectServices(_ peripheral: CBPeripheral) {
        linkState = .connected
        guard inspectedPeripheral != peripheral.identifier else { return }
        inspectedPeripheral = peripheral.identifier
        status = "已连接，正在检查服务"
        lastActivity = "service_discovery_requested"
        record("service_discovery_requested", peripheralID: peripheral.identifier)
        // Discover characteristics once per connection before starting the
        // authenticated measurement session.
        peripheral.discoverServices(nil)
    }

    private func restartMeasurementConnection() {
        reader.reset()
        guard configurationLoaded, configuration.isArmed else { return }
        if let id = configuration.target?.identifier, let p = peripherals[id], p.state != .disconnected,
           central?.state == .poweredOn {
            readerRestartPending = true
            central?.cancelPeripheralConnection(p)
        } else { reconcile() }
    }

    private func terminal(_ peripheral: CBPeripheral, event: String, error: Error?) {
        let wanted = configurationLoaded && configuration.isArmed
            && peripheral.identifier == configuration.target?.identifier
        record(event, peripheralID: peripheral.identifier, details: errorDetails(error).merging(
            ["lastActivity": lastActivity, "willConsiderReconnect": String(wanted)], uniquingKeysWith: { a, _ in a }))
        if peripheral.identifier == configuration.target?.identifier {
            linkState = .disconnected
            gattReady = false
            reader.reset()
        }
        guard wanted else { return }
        inspectedPeripheral = nil
        pendingLoggedFor = nil
        if readerRestartPending {
            readerRestartPending = false
            record("measurement_session_reconnect")
            reconcile()
            return
        }
        var next = configuration
        let budget = ConnectionPolicy.recordingTermination(at: Date(), history: next.recentTerminations)
        next.recentTerminations = budget.history
        if budget.pause { next.isArmed = false }
        guard commit(next) else { return }
        if budget.pause {
            status = "一分钟内断开/失败 3 次，已暂停；等秤休眠后重新开始"
            record("reconnect_circuit_open", peripheralID: peripheral.identifier)
        } else {
            record("rearming_after_terminal", peripheralID: peripheral.identifier)
            reconcile()
        }
    }

    private func accepts(_ peripheral: CBPeripheral) -> Bool {
        configurationLoaded && configuration.isArmed && peripheral.identifier == configuration.target?.identifier
    }

    private func errorDetails(_ error: Error?) -> [String: String] {
        guard let error = error as NSError? else { return [:] }
        return ["errorDomain": error.domain, "errorCode": String(error.code), "error": error.localizedDescription]
    }

    private func record(_ name: String, peripheralID: UUID? = nil, details: [String: String] = [:]) {
        let application = UIApplication.shared
        let state: String
        switch application.applicationState {
        case .active: state = "active"
        case .inactive: state = "inactive"
        case .background: state = "background"
        @unknown default: state = "unknown"
        }
        let now = Date()
        let backgroundSeconds = state == "background" ? configuration.lastBackgroundAt.map { max(0, now.timeIntervalSince($0)) } : nil
        let event = ProbeEvent(timestamp: now, uptime: ProcessInfo.processInfo.systemUptime,
            processID: ProcessInfo.processInfo.processIdentifier, runID: runID, trialID: configuration.trialID,
            event: name, appState: state, protectedDataAvailable: application.isProtectedDataAvailable,
            backgroundSeconds: backgroundSeconds, peripheralID: peripheralID ?? configuration.target?.identifier,
            details: details)
        logger.notice("\(name, privacy: .public) state=\(state, privacy: .public)")
        let summary = "\(now.ISO8601Format())  \(name)\nstate=\(state)  background=\(Int(backgroundSeconds ?? 0))s\n\(details)"
        logLines.insert(summary, at: 0)
        logLines = Array(logLines.prefix(60))
        do {
            guard let storage else { return }
            try storage.append(event)
        } catch {
            storageError = "日志未能落盘，不能据此验收：\(error.localizedDescription)"
            logger.error("Probe log write failed")
        }
    }
}

extension WakeProbe: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .unknown: bluetoothState = "初始化中"
        case .resetting: bluetoothState = "系统重置中"
        case .unsupported: bluetoothState = "设备不支持"
        case .unauthorized: bluetoothState = "未授权"
        case .poweredOff: bluetoothState = "已关闭"
        case .poweredOn: bluetoothState = "已开启"
        @unknown default: bluetoothState = "未知状态"
        }
        record("bluetooth_state_changed", details: ["state": bluetoothState, "rawValue": String(central.state.rawValue)])
        guard central.state == .poweredOn else {
            reader.reset()
            linkState = nil
            gattReady = false
            scanDeadline?.cancel()
            scanDeadline = nil
            scanMode = nil
            inspectedPeripheral = nil
            pendingLoggedFor = nil
            status = "蓝牙不可用：\(bluetoothState)；必要时到设置开启权限和蓝牙"
            return
        }
        reconcile()
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        // Retain every restored peripheral and attach delegates immediately, even
        // if poweredOn has not arrived. Reconciliation cancels stale targets later.
        for peripheral in restored {
            peripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
            if peripheral.identifier == configuration.target?.identifier, reader.hasToken,
               peripheral.state == .connected {
                // Session keys never survive process death. Reconnect before a new login.
                readerRestartPending = true
                record("restored_crypto_session_requires_reconnect")
            }
        }
        record("central_restored", details: [
            "peripherals": restored.map { "\($0.identifier.uuidString):\($0.state.rawValue)" }.joined(separator: ","),
            "scanServices": (dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID] ?? []).map(\.uuidString).joined(separator: ",")
        ])
        reconcile()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if scanMode == "recovery" {
            guard accepts(peripheral) else { return }
            peripherals[peripheral.identifier] = peripheral
            record("target_rediscovered", peripheralID: peripheral.identifier)
            reconcile()
            return
        }
        guard scanMode == "onboarding", UIApplication.shared.applicationState == .active else { return }
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        let identity = serviceData?[Self.serviceUUID].flatMap { MiBeaconIdentity(serviceData: $0) }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "未命名 FE95 设备"
        guard serviceData?[Self.serviceUUID] != nil || name.lowercased().contains("s400")
                || name.lowercased().contains("ms104") else { return }
        guard candidates.count < 60 || candidates.contains(where: { $0.id == peripheral.identifier }) else { return }
        peripherals[peripheral.identifier] = peripheral
        let candidate = ScaleCandidate(id: peripheral.identifier, name: name, rssi: RSSI.intValue,
            identity: identity, connectable: (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue)
        if let index = candidates.firstIndex(where: { $0.id == candidate.id }) {
            candidates[index] = candidate
        } else {
            candidates.append(candidate)
            record("candidate_discovered", peripheralID: peripheral.identifier,
                details: ["connectable": candidate.connectable.map(String.init) ?? "unknown",
                          "knownScaleFamily": String(identity?.isKnownScaleFamily ?? false),
                          "rssi": String(RSSI.intValue)])
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard accepts(peripheral) else {
            record("unwanted_connection_cancelled", peripheralID: peripheral.identifier)
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        linkState = .connected
        var next = configuration
        next.lastConnection = ConnectionSnapshot(date: Date(), inBackground: UIApplication.shared.applicationState == .background)
        guard commit(next) else { return }
        pendingLoggedFor = nil
        // This records the observed callback only. It does not claim suspension,
        // screen-lock, successful authentication, or a completed measurement.
        record("connected", peripheralID: peripheral.identifier)
        inspectServices(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        terminal(peripheral, event: "connect_failed", error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        terminal(peripheral, event: "disconnected", error: error)
    }
}

extension WakeProbe: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard accepts(peripheral) else { return }
        if let error {
            record("service_discovery_failed", peripheralID: peripheral.identifier, details: errorDetails(error))
            return
        }
        let services = peripheral.services ?? []
        record("services_discovered", peripheralID: peripheral.identifier,
               details: ["services": services.map { $0.uuid.uuidString }.joined(separator: ",")])
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard accepts(peripheral) else { return }
        if let error {
            record("characteristic_discovery_failed", peripheralID: peripheral.identifier, details: errorDetails(error))
            return
        }
        record("characteristics_discovered", peripheralID: peripheral.identifier, details: [
            "service": service.uuid.uuidString,
            "characteristics": (service.characteristics ?? []).map { "\($0.uuid.uuidString):properties=\($0.properties.rawValue)" }.joined(separator: ",")
        ])
        gattReady = true
        status = "连接正常，服务已识别"
        reader.begin(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard accepts(peripheral) else { return }
        record("services_invalidated", peripheralID: peripheral.identifier)
        if reader.hasToken { restartMeasurementConnection(); return }
        inspectedPeripheral = nil
        inspectServices(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard accepts(peripheral) else { return }
        reader.subscription(peripheral, characteristic, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard accepts(peripheral) else { return }
        reader.notification(peripheral, characteristic, error: error)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard accepts(peripheral) else { return }
        reader.readyToWrite(peripheral)
    }
}

private extension CBPeripheralState {
    var linkState: PeripheralLinkState {
        switch self {
        case .connected: return .connected
        case .connecting: return .connecting
        case .disconnecting: return .disconnecting
        case .disconnected: return .disconnected
        @unknown default: return .disconnecting
        }
    }
}

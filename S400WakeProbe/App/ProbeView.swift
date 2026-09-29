import SwiftUI

struct ProbeView: View {
    @ObservedObject var probe: WakeProbe
    @State private var showDiagnostics = false
    @State private var showDevices = false
    @State private var showTokenSettings = false
    @State private var selectedCandidate: ScaleCandidate?
    @State private var exportedLog: URL?
    private let accent = Color(red: 0.05, green: 0.48, blue: 0.40)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "scalemass.fill")
                            .font(.title2).foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(accent.gradient, in: RoundedRectangle(cornerRadius: 15))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("S400但没有蓝牙网关也不要慌张")
                                .font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                            Text("自动记录 · Apple 健康").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.bottom, 4)

                    connectionCard
                    MeasurementPanel(reader: probe.reader, hasDevice: probe.configuration.target != nil)
                    ResultsPanel(service: probe.reader.pipeline)

                    if let error = probe.storageError {
                        card {
                            Label("本地存储需要处理", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline).foregroundStyle(.orange)
                            Text(error).font(.footnote)
                            Button("重试读取") { probe.retryStorage() }
                        }
                    }

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                        Text("日常直接赤脚上秤，等体脂和心率测完再下秤。保持蓝牙开启，手机留在秤附近；请勿从后台划掉 App。")
                    }.font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)

                    Button { showDiagnostics = true } label: {
                        Label("诊断与日志", systemImage: "doc.text.magnifyingglass")
                            .font(.subheadline).frame(maxWidth: .infinity)
                    }.padding(.bottom, 10)
                }.padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .tint(accent)
            .sheet(isPresented: $showDevices) { devicesSheet }
            .sheet(isPresented: $showDiagnostics) { diagnosticsSheet }
        }
    }

    private var connectionCard: some View {
        card {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: connectionSymbol)
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(probe.reader.onlineReady ? accent : .secondary)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 5) {
                    Text(probe.reader.onlineReady ? "可以称重" : probe.connectionTitle)
                        .font(.title3.bold())
                    Text(connectionSubtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 9) {
                statePill("蓝牙", probe.bluetoothState, good: probe.bluetoothState == "已开启")
                statePill("自动连接", probe.configuration.isArmed ? "已开启" : "已暂停", good: probe.configuration.isArmed)
            }
            if let last = probe.configuration.lastConnection {
                HStack(spacing: 4) {
                    Text("最近连接")
                    Text(last.date, format: .dateTime.month().day().hour().minute())
                    Text(last.inBackground ? "· 后台" : "· 前台")
                }.font(.caption).foregroundStyle(.secondary)
            }
            if probe.configuration.target == nil {
                Button("添加体脂秤") { showDevices = true }
                    .buttonStyle(.borderedProminent)
            } else {
                HStack {
                    Button(probe.configuration.isArmed ? "暂停自动连接" : "开启自动连接") {
                        if probe.configuration.isArmed { probe.stop() } else { probe.arm() }
                    }.buttonStyle(.bordered)
                    Spacer()
                    Button("设备设置") { showDevices = true }
                }.font(.subheadline)
            }
        }
    }

    private var connectionSymbol: String {
        if probe.reader.onlineReady { return "checkmark.circle.fill" }
        if probe.configuration.isArmed { return "antenna.radiowaves.left.and.right" }
        return "pause.circle"
    }

    private var connectionSubtitle: String {
        if probe.configuration.target == nil { return "先选择你自己的体脂秤" }
        if !probe.configuration.isArmed { return "开启后，iPhone 会等待这台秤出现" }
        if let error = probe.reader.errorMessage { return error }
        if !probe.reader.hasToken { return "需要登录凭据才能读取测量" }
        if probe.reader.onlineReady { return "连接已就绪，直接上秤即可" }
        return probe.reader.status
    }

    private func statePill(_ title: String, _ value: String, good: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(good ? accent : Color.secondary).frame(width: 6, height: 6)
            Text("\(title) \(value)")
        }.font(.caption).foregroundStyle(good ? accent : .secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(good ? accent.opacity(0.09) : Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
    }

    private var devicesSheet: some View {
        NavigationStack {
            List {
                if let target = probe.configuration.target {
                    Section("已保存设备") {
                        Text(target.name).font(.headline)
                        LabeledContent("广播 MAC", value: target.advertisedMAC ?? "未提供")
                        Text(target.identifier.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Section("登录") {
                        Button(probe.reader.hasToken ? "登录凭据设置" : "配置登录 token") {
                            showTokenSettings = true
                        }
                        Text("凭据只保存在此 iPhone 的钥匙串中。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button(probe.scanMode == "onboarding" ? "停止扫描" : "扫描附近设备 · 30 秒") {
                        if probe.scanMode == "onboarding" { probe.stopDiscovery() } else { probe.discover() }
                    }.disabled(probe.configuration.isArmed)
                    if probe.configuration.isArmed {
                        Text("更换设备前，先在首页暂停自动连接。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(probe.candidates) { candidate in
                        Button { selectedCandidate = candidate } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(candidate.name).font(.headline)
                                Text(candidate.identity?.advertisedMAC ?? candidate.id.uuidString)
                                    .font(.caption.monospaced())
                                Text("信号 \(candidate.rssi) dBm")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.foregroundStyle(.primary)
                        }.disabled(probe.configuration.isArmed)
                    }
                } header: {
                    Text("附近的体脂秤")
                } footer: {
                    Text("轻踩唤醒秤后扫描。请核对名称与 MAC；FE95 也可能属于其他米家设备。")
                }
            }
            .navigationTitle("设备设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { showDevices = false } }
            .confirmationDialog("保存为你的体脂秤？", isPresented: Binding(
                get: { selectedCandidate != nil }, set: { if !$0 { selectedCandidate = nil } }
            ), titleVisibility: .visible) {
                if let c = selectedCandidate {
                    Button("保存此设备") { probe.select(c); selectedCandidate = nil; showDevices = false; probe.arm() }
                }
                Button("取消", role: .cancel) { selectedCandidate = nil }
            }
        }.tint(accent)
            .sheet(isPresented: $showTokenSettings) { TokenSetupView(reader: probe.reader) }
    }

    private var diagnosticsSheet: some View {
        NavigationStack {
            List {
                Section("当前状态") {
                    Text(probe.status)
                    Text(probe.reader.status)
                    Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                }
                Section("导出") {
                    Button("准备最新日志") { exportedLog = probe.exportLog() }
                    if let exportedLog { ShareLink("分享日志文件", item: exportedLog) }
                    Text("日志包含设备标识与时间，不包含密钥和测量数值。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("最近事件") {
                    ForEach(Array(probe.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }.navigationTitle("诊断日志").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { showDiagnostics = false } }
        }.tint(accent)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }
}

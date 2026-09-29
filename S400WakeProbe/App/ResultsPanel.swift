import SwiftUI

struct ResultsPanel: View {
    @ObservedObject var service: MeasurementService
    @State private var profileSheet = false
    @State private var historySheet = false
    @State private var verificationSheet = false
    @State private var permissionSheet = false
    private let accent = Color(red: 0.05, green: 0.48, blue: 0.40)

    var body: some View {
        VStack(spacing: 16) {
            latestCard
            healthCard
        }
        .sheet(isPresented: $profileSheet) { profiles }
        .sheet(isPresented: $permissionSheet) { permissions }
        .sheet(isPresented: $verificationSheet) { MetricVerificationView(service: service) }
        .sheet(isPresented: $historySheet) {
            NavigationStack {
                List(displayRecords) { record in result(record).padding(.vertical, 7) }
                    .navigationTitle("称重记录").toolbar { Button("完成") { historySheet = false } }
            }
        }
    }

    private var displayRecords: [OnlineMeasurement] {
        guard service.selectedUser != nil else { return service.records }
        return service.records.filter { $0.belongs(to: service.selectedUser) }
    }

    private var latestCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("最近一次测量", systemImage: "scalemass").font(.headline)
                Spacer()
                Button("历史") { historySheet = true }.font(.subheadline)
            }
            if let record = displayRecords.first {
                result(record)
            } else {
                Text(service.selectedUser == nil ? "还没有测量记录。连接就绪后，直接赤脚上秤。" : "还没有本人的测量记录。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("健康同步", systemImage: "heart.fill").foregroundStyle(.pink).font(.headline)
                Spacer()
                if service.syncing { ProgressView() }
            }
            HStack {
                Label("本人资料", systemImage: "person.crop.circle").font(.subheadline)
                Spacer()
                Button(service.selectedUser == nil ? "选择并确认" : "查看") { profileSheet = true }
            }
            if let user = service.selectedUser {
                Text(user.summary).font(.footnote).foregroundStyle(.secondary).privacySensitive()
            } else {
                Text("先确认属于你的米家资料，其他用户和访客结果只留在本机。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Divider()
            Text(service.healthStatus).font(.subheadline)
            if service.syncedWeightCount > 0 {
                Text("已同步 \(service.syncedWeightCount) 次称重").font(.caption).foregroundStyle(.secondary)
            }
            if service.journal.automaticHealthExport {
                if !service.missingPermissions.isEmpty {
                    Text("仅同步你允许的项目。未允许：\(service.missingPermissions.map(\.title).joined(separator: "、"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("重试待同步记录") { service.syncPending() }.disabled(service.syncing)
                    Spacer()
                    Button("暂停同步") { service.pauseHealthExport() }
                }.font(.footnote)
            } else {
                Button("开启 Apple 健康同步") { service.requestHealthAuthorization() }
                    .buttonStyle(.borderedProminent).disabled(service.selectedUser == nil)
            }
            Button("查看健康权限") {
                service.checkHealthPermissions()
                permissionSheet = true
            }.font(.footnote)
            if !service.mappingVerified {
                Text("体重和 BMI 可先同步。体脂率、心率需与秤上的同一次结果核对；去脂体重由体重与已核对体脂率计算。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("核对体脂率与心率") { verificationSheet = true }
                    .font(.footnote).disabled(service.selectedUser == nil)
            }
            if let issue = service.issue { Text(issue).font(.footnote).foregroundStyle(.orange) }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }

    @ViewBuilder private func result(_ record: OnlineMeasurement) -> some View {
        let values = record.metrics(for: service.selectedUser, mappingVerified: service.mappingVerified)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.weightKg, format: .number.precision(.fractionLength(1)))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                Text("kg").foregroundStyle(.secondary)
                Spacer()
                Text(record.inBackground ? "后台收到" : "前台收到").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 20) {
                if let bmi = values[.bmi] { metric("BMI", String(format: "%.1f", bmi)) }
                if let fat = values[.bodyFat] { metric("体脂率", String(format: "%.1f%%", fat*100)) }
                if let rate = values[.heartRate] { metric("心率", String(format: "%.0f 次/分", rate)) }
            }
            if let lean = values[.leanMass] { Text("去脂体重 \(lean, specifier: "%.1f") kg · 由体脂率计算").font(.caption).foregroundStyle(.secondary) }
            Text(record.measuredAt, format: .dateTime.month().day().hour().minute().second()).font(.caption)
            if record.timeNeedsReview {
                Label("时间需核对，暂不写入健康", systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.orange)
            } else if !record.belongs(to: service.selectedUser) {
                Text("用户归属未确认 · 仅存本机").font(.caption).foregroundStyle(.orange)
            } else if record.exportedVersions[HealthMetric.weight.rawValue] == record.revision {
                Label("体重已写入健康", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(accent)
            } else { Text(record.exportError ?? "已保存本机 · 等待健康同步").font(.caption).foregroundStyle(.secondary) }
        }.privacySensitive()
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value).font(.subheadline.bold()) }
    }
    private var profiles: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(service.users) { user in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(user.summary).privacySensitive()
                            if user == service.selectedUser { Label("已确认为本人", systemImage: "checkmark.circle.fill") }
                            else { Button("这是我的资料") { service.selectUser(user); profileSheet = false } }
                        }
                    }
                } footer: { Text("沿用米家原有资料。请选择你自己的用户；App 只自动同步这位用户的结果。") }
            }.navigationTitle("本人资料").toolbar { Button("完成") { profileSheet = false } }
        }
    }
    private var permissions: some View {
        NavigationStack {
            List {
                Section("写入权限") {
                    ForEach(HealthMetric.allCases, id: \.rawValue) { metric in
                        HStack {
                            Text(metric.title)
                            Spacer()
                            Text(service.permissionLabel(for: metric)).foregroundStyle(.secondary)
                        }
                    }
                    Button("刷新权限状态") { service.checkHealthPermissions() }
                }
                Section("更改已有选择") {
                    Text("在 iPhone 打开“健康”App → 右上角头像 → 隐私下的“App” → “S400但没有蓝牙网关也不要慌张”，再按自己的意愿更改写入开关。")
                    Text("本 App 会尊重未允许的项目。已有选择需要在健康中手动修改，App 内再次申请不一定会重新弹出系统授权页。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if service.hasUndecidedPermissions {
                    Section {
                        Button("申请尚未选择的项目") { service.requestUndecidedPermissions() }
                    }
                }
            }.navigationTitle("健康写入权限").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { permissionSheet = false } }
        }
    }
}

private struct MetricVerificationView: View {
    @ObservedObject var service: MeasurementService
    @Environment(\.dismiss) private var dismiss
    @State private var fat = ""
    @State private var heart = ""
    @State private var message: String?
    @State private var selectedRecordID: String?
    var eligible: [OnlineMeasurement] {
        service.records.filter { $0.belongs(to: service.selectedUser) && !$0.timeNeedsReview && $0.candidateBodyFatPercent != nil && $0.candidateHeartRate != nil }
    }
    var record: OnlineMeasurement? {
        eligible.first { $0.id == selectedRecordID }
    }
    var body: some View {
        NavigationStack {
            Form {
                if let record {
                    Section("核对同一次测量") {
                        Picker("测量记录", selection: $selectedRecordID) {
                            ForEach(eligible) { r in
                                Text(r.measuredAt, format: .dateTime.month().day().hour().minute().second()).tag(Optional(r.id))
                            }
                        }.onChange(of: selectedRecordID) { fat = ""; heart = ""; message = nil }
                        Text(record.measuredAt, format: .dateTime.month().day().hour().minute().second())
                        Text("\(record.weightKg, specifier: "%.1f") kg")
                        Text("输入秤上显示的体脂率和心率。若不记得，等下一次测量结束时再核对即可。")
                        TextField("体脂率（%）", text: $fat).keyboardType(.decimalPad)
                        TextField("心率（次/分）", text: $heart).keyboardType(.numberPad)
                        if let message { Text(message).foregroundStyle(.orange) }
                        Button("校验并启用指标") {
                            guard let f = Double(fat.replacingOccurrences(of: ",", with: ".")), let h = Int(heart) else { message = "请输入有效数值"; return }
                            do { try service.verifyMapping(record: record, bodyFat: f, heartRate: h); dismiss() }
                            catch { message = "与这条测量的报文不一致，请核对时间和数值；尚未启用指标同步。" }
                        }.disabled(fat.isEmpty || heart.isEmpty)
                    }
                } else { Text("需要先收到一条属于你的完整体成分结果。") }
            }.navigationTitle("核对指标").toolbar { Button("完成") { dismiss() } }
                .onAppear { if selectedRecordID == nil { selectedRecordID = eligible.first?.id } }
        }
    }
}

import SwiftUI

struct MeasurementPanel: View {
    @ObservedObject var reader: ScaleSessionController
    let hasDevice: Bool
    @State private var configureToken = false
    private let accent = Color(red: 0.05, green: 0.48, blue: 0.40)

    var body: some View {
        Group {
            if let weight = reader.liveWeight, weight > 0 {
                VStack(alignment: .leading, spacing: 12) {
                    Label(reader.liveStable ? "体重已稳定" : "正在称重", systemImage: "figure.stand")
                        .font(.headline).foregroundStyle(accent)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(weight, format: .number.precision(.fractionLength(1)))
                            .font(.system(size: 48, weight: .semibold, design: .rounded))
                        Text("kg").foregroundStyle(.secondary)
                    }.privacySensitive()
                    Text(reader.status).font(.footnote).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
            } else if hasDevice && (!reader.hasToken || reader.errorMessage != nil || !reader.hasOnlineProfile) {
                VStack(alignment: .leading, spacing: 12) {
                    Label(reader.credentialUnavailable ? "凭据暂时不可读" : (reader.hasToken ? "连接需要处理" : "完成登录设置"),
                          systemImage: reader.hasToken || reader.credentialUnavailable ? "exclamationmark.triangle" : "key")
                        .font(.headline)
                    Text(reader.errorMessage ?? reader.status).font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        if reader.credentialUnavailable {
                            Button("重新检查并连接") { reader.retry() }.buttonStyle(.borderedProminent)
                        } else {
                            Button(reader.hasToken ? "登录设置" : "配置登录 token") { configureToken = true }
                                .buttonStyle(.borderedProminent)
                        }
                        if reader.hasToken && reader.errorMessage != nil {
                            Button("重试连接") { reader.retry() }.buttonStyle(.bordered)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
            }
        }.sheet(isPresented: $configureToken) { TokenSetupView(reader: reader) }
    }
}

struct TokenSetupView: View {
    @ObservedObject var reader: ScaleSessionController
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var error: String?
    @State private var confirmRemoval = false
    @State private var showNotices = false

    var body: some View {
        NavigationStack {
            Form {
                Section("体脂秤登录 token") {
                    SecureField("24 位十六进制", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .privacySensitive()
                    Text("这是 12 字节的 BLE login token，不是 bindkey，也不是小米账号密码。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if reader.hasToken { Label("已保存；留空不会修改", systemImage: "key.fill").font(.footnote) }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                    Button("保存并连接") {
                        do { try reader.saveToken(token); token = ""; dismiss() }
                        catch let failure as ScaleProtocolError { error = failure.message }
                        catch { self.error = "钥匙串保存失败，请解锁手机后重试" }
                    }.disabled(token.isEmpty)
                }
                Section("如何获取") {
                    Text("用绑定这台秤的米家账号，在自己的 Mac 运行一次性 token 提取工具。选择与米家相同地区，找到你的 S400，只将它的 24 位 token 填在这里。")
                    Text("项目 docs/TOKEN_SETUP.md 提供具体步骤。无需在聊天中发送账号密码或 token，也不要移除或重置体脂秤。")
                    Link("查看提取工具项目", destination: URL(string: "https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor")!)
                }
                Section {
                    Text("Token 按体脂秤标识保存在此 iPhone 的钥匙串，不同步 iCloud。首次解锁后允许后台读取，不进入诊断导出。")
                        .font(.footnote)
                    if reader.hasToken {
                        Button("移除已保存的 token", role: .destructive) { confirmRemoval = true }
                    }
                    Button("开源许可") { showNotices = true }
                }
            }
            .navigationTitle("登录设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { token = ""; dismiss() } }
            .onDisappear { token = "" }
            .confirmationDialog("移除后将停止读取称重，已保存记录仍保留", isPresented: $confirmRemoval) {
                Button("移除 token", role: .destructive) {
                    do { try reader.removeToken(); dismiss() }
                    catch { self.error = "钥匙串删除失败，请重试" }
                }
            }
            .sheet(isPresented: $showNotices) {
                NavigationStack {
                    ScrollView {
                        Text(notices).font(.caption.monospaced()).padding().textSelection(.enabled)
                    }.navigationTitle("开源许可").toolbar { Button("完成") { showNotices = false } }
                }
            }
        }
    }

    private var notices: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "许可文件读取失败" }
        return text
    }
}

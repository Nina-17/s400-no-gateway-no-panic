# S400但没有蓝牙网关也不要慌张 · S400 No Gateway, No Panic 🟢

秤在地上，iPhone 在附近，蓝牙网关今天可以休息。这个 iOS App 直接连接 Xiaomi Body Composition Scale S400，保存本人的完整测量，并把获授权的项目同步到 Apple 健康。名字很长，连接流程尽量短。

**当前版本：0.5.1 / build 15。** 这是源代码项目，需要自行签名并在真机安装；每位开发者应使用自己的唯一 Bundle ID。

## 能做什么

- 📡 通过 iPhone 的 CoreBluetooth 直接等待、连接 S400。支持已验证的在线登录、资料同步和完整体成分结果；日常不需要打开米家或准备独立蓝牙网关。
- ⚖️ 首页显示连接就绪、实时体重和最近一次**本人的**测量，历史页也按已确认用户筛选。秤完成体脂与心率后，结果留在本机保护存储。
- ❤️ 按项目写入 Apple 健康：体重、BMI、经同次秤面核对的体脂率，以及由体重和体脂率算出的去脂体重。心率可以单独授权；用户未授权时不写，也不反复弹窗劝你点头。
- 🧾 保留有界诊断日志、设备设置和手动重试入口。日志能帮忙找问题，但不包含 token、会话密钥或测量数值。

旧版的 1/15 分钟延迟连接实验和提前断开采样已从日常 App 移除。新图标已经接入，首页、设备设置和健康权限页也已整理。钥匙串在重启后暂时不可读时，App 会在解锁/回前台后重新检查，不会立刻把它判成“token 离家出走”。

## 开始使用

1. 在“设备设置”中选择自己的 S400，并保持自动连接开启。**新设备仍需完成开发者辅助的米家用户资料导入**，目前不是普通用户的一键配对流程。
2. 如未配置登录 token，按[一次性获取指南](docs/TOKEN_SETUP.md)在自己的设备上操作，只在 iPhone App 内输入。不要在聊天、Issue 或截图中发送 token、账号密码。
3. 在“健康同步”中确认本人资料，自行选择写入权限。体脂率和心率的字段须先与**同一次**秤面结果核对；其他用户和访客结果不会作为你的健康数据写入。
4. 日常保持 iPhone 蓝牙开启、手机在秤附近，直接赤脚上秤，等体脂和心率完成再下秤。不要从多任务界面强制划掉 App；iOS 的后台唤醒由系统决定，不能承诺每次、每种状态都必定连接。

## 已验证的边界

0.5.0 的真机测试中，秤面体脂和心率流程正常；脱敏日志确认后台收到完整的 32 字段结果、记录已保存，且获授权的 4 种健康项目写入成功。0.5.1 调整显示名称和首页标题；iOS 构建通过。核心 **33 项 XCTest 全部通过**，包括旧配置迁移、身份筛选、去重和协议边界。详细证据与限制见[验证记录](docs/VALIDATION.md)和[测量与健康说明](docs/MEASUREMENT_AND_HEALTH.md)。

曾观察到锁屏后台连接与进程恢复；这证明对应测试条件下成功，不是对 iOS 未来每次唤醒的保证。免费开发签名也会到期，需要适时重新签名安装。项目不会从 Apple 健康读取历史数据。

## 开发与隐私

使用 XcodeGen、Xcode 和真机。构建时将 `S400_APP_BUNDLE_ID` 设为你独有的标识，并选自己的 Signing Team；项目中的 `org.example.s400nogateway` 只是示例。已经安装过旧版本时，升级构建必须继续使用**原来的 Bundle ID 和签名团队**，否则 iOS 会把它当作另一款 App，原有钥匙串与本机记录也不会自动迁移。日志和钥匙串服务名从实际 Bundle ID 派生，不在源码中绑定某个开发者账号。

```sh
xcodegen generate
swift test
xcodebuild -project S400WakeProbe.xcodeproj -target S400WakeProbe \
  -configuration Debug -sdk iphoneos \
  S400_APP_BUNDLE_ID="your.unique.bundle.id" DEVELOPMENT_TEAM="YOUR_TEAM_ID" build
```

图标原图在 `Design/Assets.xcassets/AppIcon.appiconset`；iPhone PNG 放在 `S400WakeProbe/Resources`，由 `CFBundleIcons` 指向。图标已在真机主屏幕验证。

`Sources/ProbeCore` 保存协议、归属和连接策略；`S400WakeProbe/Bluetooth` 管理后台恢复与在线会话；`S400WakeProbe/Health` 管理本机记录和 HealthKit；`S400WakeProbe/Diagnostics` 保留有界日志。设备数据和抓包只应放在本机受保护目录，仓库通过 `.gitignore` 排除 `device-logs/`、`.build/` 等私有与构建文件。

第三方 CryptoSwift 和 token 提取工具保留各自许可，见 `S400WakeProbe/Resources/ThirdPartyNotices.txt`、`Vendor/CryptoSwift/LICENSE` 及 `Tools/TokenExtractor/LICENSE`。

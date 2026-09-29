# S400 在线称重：业务初始化为何必要

仅完成 BLE 连接、登录认证并接收通知，不足以让秤完整进入在线体脂与心率流程。早期实现能解出体重和阻抗数据，但秤面停在体重；同一台秤由米家保持连接时可以完成体脂和心率。这一对照提示差异位于认证后的业务交互，而不是“连接本身必定干扰测量”。

## 诊断边界

体重稳定、阻抗采样、体脂显示、心率采样和完整结果上传是不同事件。传输层分片 ACK 也不等于业务层初始化成功。应分别记录 `authenticated`、`initializing`、`ready`、`measuring` 和 `complete`，只在业务成功回复后显示“可以称重”。

公开 [MIoT ms103 v2 规格](https://miot-spec.org/miot-spec-v2/instance?type=urn:miot-spec-v2:device:scale:0000A07D:yunmai-ms103:2)列出 service 13/action 1 `sync`，输入包括插件能力、单位、当前时间、心率开关和用户列表。这些字段提供协议线索；仅凭规格不能确定 BLE 字节编码和完整时序。

## 正常在线会话确认的步骤

分析经过账号持有人许可、只留在本机的正常会话后，确认客户端在认证后进行了以下交互：

1. 通过 001A/001B 特征交换 `05 20 00 00 f0` 业务握手。
2. 发送两次 service 13/action 1 `sync`，并分别收到匹配事务的成功回复。请求带单位、时间、心率设置和原有用户资料。
3. 接收 service 8/event 1 的体重阶段事件，以及 service 8/event 2 的完整 32 字段身体结果。
4. 完整结果之后可能发送 service 6/action 5 的基础体重更新；该消息不是本轮体脂和心率恢复的前置条件。

因此客户端需要双向加密业务消息、独立方向计数器、分片流控、事务响应匹配、超时保护以及真实用户上下文。不能用空用户列表或猜测的心率设置覆盖设备资料。完整事件中的一些字段允许有符号数值，不能沿用“全字段非负、前两字段为零”的早期候选解析规则。

加入握手与 `sync` 后，真机前台对照中秤面体脂和心率完成、App 收到同轮完整结果。它支持“缺少认证后的业务初始化”这一根因判断；现有证据不能再细分用户列表、心率开关和能力字段各自是否为必要条件。后续后台连接和结果接收也有成功记录，但 iOS 调度、不同固件和强制退出情形仍需分别验证，见[验证记录](VALIDATION.md)。

## 复现与隐私

如需比较其他固件，先用米家做完整称重对照，再在用户许可下采集目标秤的有界 ATT/GATT 会话。只在本机解密；原始抓包可能包含无关蓝牙流量和敏感数据，不要上传仓库或 Issue。`scripts/capture_ios_bluetooth.py` 需要显式传入目标 iPhone UDID 与**自己安装的** Apple PacketLogger CLI 路径，最长采集 300 秒，输出到被 Git 忽略的 `device-logs/`。

Apple 工具入口：[Bluetooth 开发资源](https://developer.apple.com/bluetooth/)、[WWDC19 蓝牙调试](https://developer.apple.com/videos/play/wwdc2019/901/)和[蓝牙诊断描述文件](https://developer.apple.com/feedback-assistant/profiles-and-logs/?name=bluetooth)。第三方协议参考：[xiaomi-s400-live](https://github.com/nokistin/xiaomi-s400-live)；其接收实现没有本项目所需的 iOS 后台生命周期，也不能独立证明 `sync` 时序。

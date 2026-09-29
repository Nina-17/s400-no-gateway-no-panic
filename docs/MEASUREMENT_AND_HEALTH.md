# 本机测量、去重与 Apple 健康

完整在线报文先进入受保护、排除备份的本机原始记录，再进入测量 journal。解析或健康写入失败不会终止蓝牙会话。旧实验中的未验证候选报文不会自动升级为正式测量。

## 本人归属

App 只把用户在 iPhone 上确认的米家资料作为本人。导出时同时匹配设备 UUID、账号 ID、资料 ID 和用户类型；访客、未知归属和其他用户只留在本机。体重接近不能证明归属，新设备仍需导入原有用户资料。

## 字段和健康类型

| 输入 | 用途 | 边界 |
| --- | --- | --- |
| CSV 0 / 1 / 2 | 账号 ID / 资料 ID / 用户类型 | 必须与已确认资料匹配 |
| CSV 3 | 体重，原值 / 10 kg | 与 live 值和正常会话核对 |
| CSV 6 | 设备 Unix 时间 | 与接收时间相差过大时保留记录，暂不导出 |
| 用户身高 | BMI = kg / height(m)^2 | 来自已确认资料，不猜测身体 CSV 字段 |
| CSV 7 | 体脂率候选，原值 / 10 % | 须先与**同一次**秤面结果核对 |
| CSV 4 | 心率候选，整数 bpm | 同样需要同次秤面核对及单独授权 |
| 体重、体脂率 | 去脂体重 = kg × (1 − 体脂率 / 100) | 派生值，不宣称是秤直接发送的字段 |

核对界面要求选择同一次记录并输入秤面体脂率和心率；两者匹配才保存该设备的字段映射。未核对的身体字段不写入健康。App 不读取 Apple 健康历史，也不使用公开算法覆盖厂商结果。

## 去重和重试

- 本机身份为设备、账号、资料、用户类型和设备时间的 SHA-256。重复上报不会新增记录；同体重但不同时间保留为两次测量。
- 同一身份的更正增加 revision。每个健康类型使用稳定的 `syncIdentifier` 和 `syncVersion`，避免进程重启后重复写入。
- 只有 HealthKit 保存成功，才更新本地导出版本。部分授权时只写入获授权类型；日后完成字段核对或补授权，可补写缺失类型。
- 保存失败会保留待同步状态，并在新测量、受保护数据恢复或 App 回前台时重试。有限后台任务仅用于完成保存，不用于长期保活。

健康权限由 iOS 系统管理。App 的“查看健康权限”显示逐项状态；用户可在“健康”App 的隐私设置中手动修改。拒绝某项权限是有效选择，不会阻止本机保存或反复弹窗。当前核心 33 项 XCTest 覆盖用户隔离、去重、更正、时间和单位边界；真机证据及限制见[验证记录](VALIDATION.md)。

参考：[Apple HealthKit 授权](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)、[同步标识](https://developer.apple.com/documentation/healthkit/hkmetadatakeysyncidentifier)及[同步版本](https://developer.apple.com/documentation/healthkit/hkmetadatakeysyncversion)。

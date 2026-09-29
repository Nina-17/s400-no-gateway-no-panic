# 一次性获取 S400 登录 token

S400 在线 GATT 登录需要 **12 字节、24 位十六进制的 BLE login token**。它不是 32 位 bindkey，也不是小米账号密码。云端若没有返回该字段，就不要截断、补零或改填其他字段。

## 准备

需要一台装有 Python 3.12+ 的 Mac、绑定这台秤的米家账号，以及能运行本项目的 iPhone。先在项目根目录创建独立环境：

```sh
python3 -m venv .build/token-tools-env
.build/token-tools-env/bin/python -m pip install -r Tools/TokenExtractor/requirements-lock.txt
chmod +x scripts/Get-S400-Token.command
```

依赖只需安装一次；如果已经创建环境，直接进行下一步。不要把 token、账号密码、验证码、终端截图或完整工具输出贴到 Issue / 聊天中。

## 运行提取工具

1. 在 iPhone App 的“设备设置”中选定 S400，记下设备详情显示的 MAC。
2. 在 Finder 双击 `scripts/Get-S400-Token.command`（或在项目根目录运行 `./scripts/Get-S400-Token.command`）。启动器会询问目标 MAC；也可预先写入仅保存在本机、被 Git 忽略的 `.build/token-target-mac`。工具只显示匹配该 MAC 的设备。
3. 推荐在工具中选择 `q` 扫码登录。按终端**当次显示的地址**在本机浏览器打开二维码页面，用绑定设备的米家 App 扫码并确认；验证步骤由账号持有人完成。当前工具使用 `127.0.0.1:31415`，只绑定本机 loopback。若选择工具支持的密码登录，也只在本机终端输入。
4. 选择与米家 App 一致的地区，例如 `cn` 或 `sg`；不确定时可按工具提示查询所有地区。核对设备名称、MAC 与 `TOKEN` 字段，勿将 `BLE KEY` 误当 token。
5. 回到 iPhone App 的“设备设置”，输入完整的 24 位 `TOKEN` 并保存连接。App 按设备 UUID 将 token 存入本机钥匙串，不把它写进源码、配置文件或诊断日志。
6. 退出工具并关闭终端。后续日常称重不需要让 Mac 常开。

扫码成功并不保证云端一定返回 BLE token。如果字段缺失或登录失败，检查地区、设备绑定与错误类型；不要重置或重新绑定秤来碰运气，这可能改变凭据。

## 来源和限制

本项目内的提取工具来自 [Xiaomi Cloud Tokens Extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor)，固定提交 `c4db715dace9806e905153c2977608873e8ab7c9`，许可见 `Tools/TokenExtractor/LICENSE`。本地改动把二维码服务限制在 loopback，并按 `S400_TARGET_MAC` 过滤输出。项目不自动刷新云端 token。

完成 token 配置后，仍需有对应的米家用户资料才能完成当前在线初始化；新设备的资料导入目前需要开发者辅助，详见 [README](../README.md)。确认首页显示“可以称重”后，再赤脚上秤并站到体脂和心率步骤结束。Apple 健康只写入本人已核对且获授权的项目。

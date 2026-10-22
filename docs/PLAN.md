# AgentInbox 实施计划

目标：沿用标准 Agent 启动方式，把原请求送到中文 iPhone 收件箱并准确返回。
采用 Rust 1.96.1 + SQLite + SwiftUI/WidgetKit/AppIntent（iOS 17）。已有 P0 仅作协议和证据参考，不能直接当产品。

1. 接手：核对最新 Claude ordinary 证据、专用进程、正常 daemon 版本；不触碰未知 Desktop 创建。
2. 原生核心：单一 agentinbox 二进制提供 relay/host/hook/client；SQLite 事务保存请求、回复、设备与推送 outbox。先测试旧 revision、过期、内容冲突、并发唯一获胜、重启 submitting→unknown，后实现。
3. Codex：连接既有 daemon，保留原生身份与原内容；响应前复核，原引擎 adopted 回执才能确认成功。独立测试任务，不接管用户正常待答任务。
4. Claude：helper 通过私有 Unix IPC 等待；原 hook 返回值保留原问题与选择。返回只算提交，原 tool_result 才算采用。初期先使用项目配置示例；用户后续已明确批准最小合并用户级 hooks，现已安装，默认真实装载仍按入口单独验证。
5. iOS：共享 Codable 协议、Keychain、收件箱/详情/中文文字/多选/历史/机器/设置；Widget AppIntent 直答和准确深链；模拟器构建与测试。
6. 原生服务真实联调和故障测试，记录证据及入口支持矩阵；launchd/systemd、Linux构建、升级排空和回滚文档。
7. 真机/APNs/日本服务器前一次性请求设备版本、签名标识、服务器接入和部署批准。APNs私钥仅在relay文件配置，不发到聊天；本地API只监听loopback，Tailscale监听需授权。

状态机：pending / submitting / adopted / handledLocally / expired / invalidated / unknown。unknown 不自动派发。产品requestId+revision+expiresAt与原生hostId/runtimeId/sessionId/turnId/nativeRequestId/itemId绑定；缺字段原生不提供时用null并明确限制，不能臆造。展示pane不参与授权。

接口约定见 PROTOCOL.md。真实入口、模拟、历史证据分开记录。用户已授权架构实现与并行开发，不为每个代码步骤额外停工；凭据、持久权限、部署另行处理。

## 2026-10-15 离线推进

手机已签名安装但目前离线；不提前 seed 配对码，不消耗十分钟期限。继续默认 CLI、Herdr 限定入口、持久化恢复、升级守卫和实际空闲服务更新。Mac/Ubuntu 生产 host 保持 drain；原 daemon/默认 Herdr 保留。

已完成默认 Ubuntu 自动发现、Herdr 明确绑定的原生 Beta、四类进程恢复及隔离新旧二进制回滚；具体证据与限制见 STATUS。候选源码已冻结提交，实际空闲升级按 IDLE-UPGRADE-20261015 的前置门槛进行。下一项是 Claude 无额外 settings 参数的默认 hook 闭环，先准备隔离本地服务，不以设置存在替代实际加载。

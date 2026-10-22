# AgentInbox

轻量中文 Agent 决策收件箱：Rust 原生 host/relay/hook helper，SwiftUI App、WidgetKit 与 AppIntent。保留 Codex／Claude 的正常启动方式，通过原生回调回答原任务。

## 功能列表

| 功能 | 当前能力 |
| --- | --- |
| 中文收件箱 | 待决列表、请求详情、历史状态、机器在线状态和设置；展示问题来源与原任务状态。 |
| 手机回答 | App 提供单选、中文文字、多选和多问题输入，以及一次审批／拒绝界面。当前真实手机端到端验收以单选为主，其余类型不能据此算通过。 |
| Widget 直接回答 | 中号主屏幕组件展示问题、机器和短选项；简单单选通过 AppIntent 原地提交，已在真机确认不打开 App。文字、复杂问题等打开准确请求页。 |
| Widget 刷新与切题 | 手动刷新、时间线刷新、iOS 26 Widget 专用推送；已验证自动出现新题、回答后自动切到另一台机器的待决题、终态清空，以及明暗外观。系统调度不保证固定刷新间隔。 |
| APNs 主动提醒 | 真实 Sandbox APNs 提醒已送达 iPhone；默认只推送通用提醒和不透明请求 ID，正文经认证 API 获取。通知与 App 收件箱独立于 Widget 刷新。 |
| 保留现有启动习惯 | Codex 连接同一个既有 managed daemon；Claude 使用原生 hooks 和短生命周期 helper。无需统一启动命令、SDK launcher、wrapper 或 `--no-daemon`。 |
| 多机器接入 | Mac／Ubuntu 原生 host 汇入同一 relay；双主机同时待答、手机分别回答不同选项已通过，答案回到各自原任务。 |
| App 内网页登录关联 Tailscale | 最新目标：点击关联弹出官方网页登录／授权，自动返回设备目录，复用 iPhone Tailscale VPN；不手填 Secret、不用快捷指令、不创建额外节点。现有手工 API 版仅是基础实现，网页链路正在核实。[状态与边界](docs/FEATURE1-TAILSCALE.md)。 |
| 精确关联与防重放 | 绑定机器、引擎实例、原 session／turn／request，以及产品 requestId／revision／期限；稳定 responseId、事务去重、旧题拒绝、单次领取与派发。 |
| 原任务回执 | 区分待回答、提交中、已采用、已在本机处理、已过期、已失效、结果未知；只有匹配原引擎证明才标为已采用，未知结果不盲重发。 |
| 目录与会话隔离 | 默认精确匹配 canonical cwd，也可显式启用当前用户的全目录捕获；支持持久排除旧 session，仅接新会话，被排除会话的新 turn 仍排除。 |
| 设备认证与撤销 | 短期单次配对码、iOS Keychain、共享组件身份、应用层鉴权及设备撤销；Tailscale 私网不代替应用认证。 |
| 持久化与维护 | SQLite 请求／回复／推送 outbox、回执恢复、活跃 hook 排空守卫和版本回滚流程；Mac LaunchAgent、Ubuntu systemd 服务定义。 |
| 原生执行端 | 一个 Rust 二进制提供 host、relay、hook helper；目标机器无需安装 Node.js、Bun、Python、Go 或 Rust 运行环境。 |

## 接入与验收状态

截至 2026-10-17；“已实现”“已部署”和“原任务已采用”分别记录，入口支持以实际测试为准。

| 入口 | 已验证能力与边界 |
| --- | --- |
| Mac Codex CLI 0.162.0／daemon 0.162.1 | 原请求自动捕获，实体 iPhone App／Widget 单选回传、唯一原工具结果及原 turn 完成；受控本机／手机先答与部分竞争场景通过。 |
| Mac Claude Code 2.1.299 普通 CLI | 零参数启动、默认全局 hooks，单选 Beta 回到原 session／tool_use；真实活 hook 排空延期通过。[验收记录](docs/CLAUDE-DEFAULT-LIVE-RESULT.md)。 |
| Ubuntu host-a · Codex 0.162.1／0.163.0 | 0.162.1真实iPhone Widget回传及双主机切题通过；当前0.163.0已启用不限目录／仅新会话，真实捕获、APNs接受发送和本机唯一采用通过。[漏报恢复与当前配置](docs/HOST-A-CAPTURE-RECOVERY.md)、[此前真机回传](docs/UBUNTU-IPHONE-LIVE.md)、[双主机测试](docs/CONCURRENCY-PHASE1.md)。 |
| Ubuntu host-b · Codex CLI 0.162.1／daemon 0.163.0 | host 已部署，仅 example-project 精确目录的新会话；94个旧会话排除。自动捕获、本机 Alpha 唯一采用及 handledLocally 通过，手机回传待验。[部署记录](docs/HOST-B-DEPLOY.md)。 |
| Ubuntu host-b · Claude 2.1.301 普通 CLI | 正常交互式 shell 中零参数启动，默认 hook 真实捕获、自然到期恢复原生题、本机 Beta 唯一采用通过；手机远程回传待验。直接 SSH exec 未加载用户既有代理环境时曾403，正常 shell 复测通过且配置未改。[本机复测](docs/HOST-B-CLAUDE-LOCAL.md)。 |
| Herdr 0.9.3 · Mac 独立 pane | 核实原 CLI／thread 后显式绑定，单选原任务采用通过；通用 pane 自动映射、共享 daemon hook 归属和 Ubuntu Herdr 待验。[现场记录](docs/HERDR-LIVE-RESULT.md)。 |
| 原生 Codex Mac App／Claude Desktop Code tab | 尚未通过；CLI 结果不作为 Desktop 验收。 |
| iPhone App／Widget | 已在 iPhone 16 Pro／iOS 26.6.1 验证原配对、认证、真实推送、App／Widget 单选与自动切题。SDK 已移除，App／测试与 Widget 的源码部署基线均为 iOS 17；iOS 17 实机兼容仍待验。上述历史结果不替代只读 API 设备目录及新方案验收。 |

完整支持矩阵见 [STATUS](docs/STATUS.md)。物理键盘同时竞答、host 已领取／已派发手机候选后的争用，以及断网／锁屏完整矩阵仍待验收。真实产品入口的审批、文字和多选采用证明也需继续补齐；P0 或模拟引擎测试不替代这些验收。

2026-10-22 合并前本机回归：原生 **103通过、0失败、3忽略**（2项条件演练＋1个子进程入口）；iOS 单元 **118通过、0失败、6条件跳过**，核心 UI **7通过**。已保留主分支不限目录发现与当前只读 Tailscale 关联的完整回归。旧二进制回滚演练与真机现场结果单独记录，不与回归数量重复相加。当前为开发检查点。

## 构建

App 不再链接 TailscaleKit，构建无需 Go 或 SDK 预构建。手机连接由 iPhone 上的独立 Tailscale App 提供，[关联只读 API 的配置说明](docs/FEATURE1-TAILSCALE.md)。

```sh
cargo build --release --locked
cargo test --locked
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/AgentInbox.xcodeproj -scheme AgentInbox \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/AgentInboxBuild CODE_SIGNING_ALLOWED=NO build
```

执行端只需编译产物与OS依赖，不需要Rust/Go/Node/Bun/Python。Mac已核对ARM64 Mach-O，动态系统依赖libSystem与libiconv。Linux x86_64 静态 ELF 已构建且核对无共享库依赖，重建见[docs/LINUX.md](docs/LINUX.md)；已在 Ubuntu 原生执行，日本 relay、host-a 与 host-b host 已部署；各入口验收范围见上表。

## 目录

- `src/store.rs`, `relay.rs`, `apns.rs`, `device_admin.rs`：SQLite事务、认证配对/撤销、API与推送outbox。
- `src/host.rs`, `hook.rs`, `adapters/`：原生请求发现、精确绑定、单次派发、采用证明、终态回执与排空。
- `ios/`：独立App/Widget/Xcode工程、中文交互、共享状态/Keychain、稳定回复journal。
- `tests/`：单元、HTTP进程、并发与故障恢复测试。
- `config/`, `deploy/`：仅模板，不包含真实凭据；已安装实例独立存放受限配置。

联调记录、截图、日志和运行状态保存在本地 `evidence/`，不纳入 Git。文档中的证据路径需在保留这些本地记录的工作目录查看。

## 本地运行

```sh
agentinbox relay --config /absolute/private/relay.local.json
agentinbox host /absolute/private/host.local.json
agentinbox hostctl /absolute/private/state/ipc/hook.sock status
```

先按[CORE](docs/CORE.md)、[ADAPTERS](docs/ADAPTERS.md)填写本地受限配置。开发fixture是明确公开的非秘密测试值，禁止用于真实设备或服务器。API默认仅127.0.0.1，Tailscale本身不代替应用认证；已批准的日本实例通过 tailnet HTTPS8443 提供认证 API。其他范围部署须另获授权。

## 可靠性

每个答案绑定hostId、引擎实例、session/thread、turn、native request/item/tool_use_id，产品requestId/revision/期限，以及稳定responseId。手机仅用选项ID。SQLite事务保证唯一获胜，同ID改内容拒绝；主机领取并fsync后只派发一次。原引擎精确证明才能显示已采用，结果未知不自动重派。重启不能继承旧hook callback，终态回执恢复不等于重发答案。

设备丢失后的服务器撤销见[DEVICE-ADMIN](docs/DEVICE-ADMIN.md)。配置/安装、版本排空与回滚见[OPERATIONS](docs/OPERATIONS.md)。普通使用见[USER-GUIDE](docs/USER-GUIDE.md)。真机/部署最短信息清单见[DEVICE-DEPLOY-CHECKLIST](docs/DEVICE-DEPLOY-CHECKLIST.md)。秘密凭据在本机配置，不发到聊天。

## 公开版本与本地配置

公开源码中的部署主机、地址和运行记录已使用示例值；历史验收记录经脱敏后仅说明测试过程，不能直接当作安装配置。`dev.matianyi.agentinbox` 及其 App Group/Keychain 标识是保留兼容性的公开产品标识，不是凭据。真机签名时通过 `DEVELOPMENT_TEAM` 显式指定自己的团队；源码不提供签名团队默认值。

`dist/` 不随源码发布；请按上面的构建命令生成本机产物，Linux 交叉构建仍输出到本地 `dist/linux/`。发布二进制前应使用 Rust 路径映射，并检查产物中的个人路径及凭据。`scripts/claude-hook-timeout.py` 是历史验收辅助程序，需要匹配记录的本地二进制与私有证据，普通构建和测试不依赖它。

DEBUG 配对文件导入和 LLDB 预填辅助工具使用 `relay.example.ts.net` 示例目的地；开发者需在自己的本地副本中填写目的地后再做真机调试。正常 App 配对可在界面填写服务器。iOS 测试证据默认写入测试进程临时目录，也可在 XCTest runner 环境中指定 `AGENTINBOX_NATIVE_PROOF_FILE`、`AGENTINBOX_CLEANUP_PROOF_FILE`、`AGENTINBOX_PAIRING_PROOF_FILE` 或 `AGENTINBOX_WIDGET_PROOF_FILE`。

本地 `.env`、私钥、证书、profiles、运行数据库、`evidence/` 和 `.superpowers/` 不应提交。修改 `.gitignore` 不会删除旧 Git 历史；将已有私有仓库改为 public 前，还需清理所有历史分支、标签、PR 引用及附件。

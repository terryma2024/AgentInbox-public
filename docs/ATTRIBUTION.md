# 来源与许可记录

2026-10-21：内置 Tailscale 方案已废弃，当前方案为[复用 iPhone 上的独立 Tailscale VPN＋只读 API 自动获取设备](FEATURE1-TAILSCALE.md)。已从源码、工程、资源与构建脚本移除 TailscaleKit；本轮 Release App／Widget 产物核对无该框架或旧许可证资源。独立 Tailscale App 由用户单独安装，不随 AgentInbox 分发。

旧 SDK 固定提交与许可证归属仍保留在[历史方案归档](FEATURE1-TAILSCALE-EMBEDDED-ARCHIVED.md)，适用于迁移前历史产物；不将移除依赖追溯为旧产物没有许可义务。

本项目新建 Rust 与 Swift 实现；协议研究参考用户已有的 task-2/P0 Rust 探针和现场证据，旧目录保留原样。HTTP库 tiny_http 0.12.0 被局部 vendored，完整保留 MIT 与 Apache-2.0 许可证；只修复 worker 队列预留计数，补丁与红绿回归见 vendor/tiny_http/AGENTINBOX-PATCH.md。没有 fork 或复制 HAPI，没有引入旧 Happyword 游戏运行时，也没有拷贝 Agent 登录凭据。设计来源与官方文档链接见 SOURCES.md。

Rust 第三方版本完整锁定 Cargo.lock：serde/serde_json、rusqlite（bundled SQLite）、tiny_http、reqwest/rustls、p256、base64、uuid、sha2、tungstenite、fs2 及其传递依赖。重新分发应一并审查各 crate 的 LICENSE/NOTICE（通常 MIT/Apache-2.0/BSD/ISC；SQLite 源码另有公有领域声明），Cargo.lock 是版本清单，不替代许可证全文。尚未公开发布；公开分发前补齐依赖许可证包。

XcodeGen、Rust/Cargo、Zig、OpenCLI 只用于本机开发／构建／已授权账号操作，不属于运行端常驻依赖。Apple SDK/framework 使用系统设施。目标主机运行依赖见 TOOLCHAIN.md、LINUX.md 和实际产物证据。

# Linux 第二轮本机构建（2026-10-15）

本轮仅在 Mac 开发机使用现有 `scripts/build-linux-musl.sh` 增量构建，编译成功（Cargo release 3.14 秒）。使用缓存的官方 Rust 1.96.1 compiler、Apple host/Linux musl std 与 Zig 0.15.2；四个官方归档均经脚本固定 SHA256 校验，未重新下载或安装工具。

最终产物：`dist/linux/agentinbox`，**7,127,248 bytes**，x86-64 `ELF64 EXEC`，静态链接、stripped。SHA256：`fa74df1ca0dd08ae2eeb71e44b9bd18ca8dfb41db327511f42642d3d7aa2537f`。

最终 source manifest SHA256：`49e2dbcf964e87a6807255155efb649e31edf94924c13794910850e4085ebb7f`。全部 **38** 项编译输入摘要均匹配，包含 `src/host.rs`、`src/relay.rs` 与完整 `vendor/tiny_http` 源码／许可证。编译前、编译后和发布的 manifest 字节完全一致；最终对当前源码执行 `shasum -c` 也全部通过。测试源码不属于该脚本的编译输入 manifest；此构建记录不额外宣称原生测试方法数量或运行结果。

LLVM readelf 确认 x86-64、没有 `INTERP` program header、没有 `NEEDED` 共享库。未在 Linux 上执行该二进制。

旧 `dist/linux` 的二进制、`SHA256SUMS`、`SOURCE-SHA256SUMS` 已完整保存在 `/private/tmp/AgentInboxRollbackBaseline/linux`；旧 binary SHA256 为 `7113dd64f0851a852a1325ca8d646a416acc5e81ac210fd9a1dd60a4340588a1`，与旧 SHA256SUMS 再核对一致。基线只作后续 rollback 演练材料，本轮没有执行 rollback。

本轮没有 SSH、部署、重启或修改已安装服务，没有读取 host token、配对码或其他秘密，没有操作手机。没有修改 `src`、构建脚本、`docs/STATUS` 或 `docs/OPERATIONS`。

独立证据目录：`evidence/linux-round2-build/`，含 `preflight.json`、`build.log`、`verification.json`、`elf.txt`、`source-before.sha256`、`source-after.sha256`、`SOURCE-SHA256SUMS`、`SHA256SUMS` 与 `source-check.txt`。这仅证明本机构建、静态 ELF 及源码一致性，不替代实际升级／排空／回滚、手机或原生 Agent 验收。

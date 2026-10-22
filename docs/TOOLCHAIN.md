# 构建版本与 OS 依赖

开发实测：macOS / Apple Silicon，Rust/Cargo 1.96.1（Homebrew），Xcode27.0 / Build27A266a，XcodeGen2.45.4。工具链channel锁定1.96.1，依赖实际版本由Cargo.lock锁定；iOS无第三方Swift包。

运行目标：Mac/Ubuntu仅原生agentinbox。Rust/Go/Node/Bun/Python/XcodeGen不属于执行端运行依赖。构建机需要Rust和C工具链（bundled SQLite、TLS crypto编译）；iOS构建需要Xcode。Mac动态系统依赖以evidence/native-dependencies.txt核对；Linux目标建议musl，实际二进制依赖必须在构建Ubuntu后用readelf核验。

本机未新增Go、Rust工具链或Linux target，只下载Cargo.lock所列构建依赖。没有安装OS服务/开机启动。当前Mac仅Apple目标std，本轮不能声称Linux产物/运行验收完成。

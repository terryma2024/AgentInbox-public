# Screens 风格 Tailscale 只读设备集成

> 2026-10-21 后续实机核查确认 Screens 首次关联使用 Tailnet ID＋客户端密钥。用户确认此前记忆有误，并明确要求“按现有方案继续”，在手机填写凭据做真机验证；本文设计恢复为当前方案。网页授权探索保留在核查记录中，不计为本方案功能。

2026-10-21 用户已确认：按 Screens 官方方式实现 Tailnet ID＋仅 Devices/Core Read 的 OAuth Client Secret，保存在本机 Keychain；自动更新设备，复用 iPhone 独立 Tailscale VPN，不创建额外节点，不再要求快捷指令。

## 依据与体验

参考图位于 `/Users/developer/Documents/Screens参考图/`，五张图与会话附件一致：设备入口及数量、设备列表、关联 Tailnet／管理控制台／服务状态／刷新／取消关联菜单。Screens 截图中的管理网页登录不能视为第三方 OAuth SSO 的证明。

[Edovia 配置说明](https://help.edovia.com/en/screens-5/connecting-anywhere/tailscale)要求 Tailnet ID 和 OAuth Client Secret、Devices/Core Read。[Tailscale OAuth clients](https://tailscale.com/docs/features/oauth-clients)定义令牌生成与续期；[官方 API](https://tailscale.com/api)的设备接口要求 `devices:core:read`。本机下载的 OpenAPI 位于忽略目录 `evidence/tailscale-api/openapi.txt`。

## 架构与凭据

App 内关联表单输入 Tailnet ID 和 SecureField Client Secret。先验证 token 与设备响应，再原子更新一个 Keychain 项中的关联配置；关联失败保留旧关联。凭据仅 App 私有 Keychain，ThisDeviceOnly、不 iCloud 同步，不写 defaults、设备快照、日志、URL、附件，不共享给 Widget、daemon 或 relay。Token 只在内存缓存，过期前重新换取；只申请 `devices:core:read`，不申请标签、auth_keys 或写权限。固定 HTTPS `api.tailscale.com`，无 cookie、缓存或重定向；有超时与响应大小限制。HTTP 状态映射为脱敏用户错误，拒绝透传可能含秘密的响应内容。取消关联删除本机 API 配置、token 和候选列表，保留 AgentInbox Keychain 配对及回复记录；不撤销或删除远端 OAuth client、设备。

## 设备同步

新增 API actor 实现 OAuth token 交换及 GET `/api/v2/tailnet/{tailnet}/devices`。Tailnet ID 仅允许安全单路径标识，拒绝 URL/path/query 注入。设备身份优先 nodeId、兼容 legacy id；列表重排、改名、IP 更换不生成新机。API 的 hostname、name、addresses、os、clientVersion 映射为设备展示；版本明确为 Tailscale 版本，AgentInbox 版本来自 daemon。connectedToControl 只是控制面最近连接状态，不代表手机 VPN 已连接或服务可达；缺失信息显示未知，不用 lastSeen 推算在线。

TailnetStore 整合自动同步，前台首次/恢复及手动刷新先更新列表，再用已有固定 Tailnet IP 只读 daemon 探测和既有授权中转对账。切换／取消关联使旧在途结果失效；单次请求串行合并，不并发无限重试，429/离线保留旧列表并显示上次更新时间和错误。缓存与当前 Keychain 中 Tailnet 一致才恢复，换账号不能混入旧设备。OAuth 凭据从不进入探测；自动发现不发送应用凭据，正常应用请求仍使用已保存中转。用户明确点击设备详情“设置为中继服务器”时，向页面所显示的候选 Tailscale 域名发送现有应用配对凭据，使用当前协议／端口请求 `/v1/hosts`，禁止重定向，兼容响应与认证通过后才保存。失败／取消／配置变化保留原地址；不依赖 8788 发现，不自动部署中继。切换后以持久化连接修订号隔离 App 与 Widget 缓存、迟到响应和旧操作。

## 界面与迁移

机器页 Tailscale 区展示关联状态、设备数量、上次更新、关联／刷新／取消关联、管理控制台和服务状态链接。设备页显示完整 Tailscale 域名和“设置为中继服务器”，保留 daemon 与一次性应用配对。旧快捷指令／手工导入实现可暂作兼容入口，但主流程不依赖其运行；API 关联时隐藏导入操作，防止来源混用。旧 SDK 继续移除，不恢复 TailscaleKit 或节点登录。首轮无 API 关联时的旧导入缓存明确标为历史快照；不会静默当作 API 关联。

## 验收

测试覆盖表单注入拒绝、精确只读 token/request、缓存与续期、401 一次重试、403/429、错误脱敏、大小限制、元数据/身份、持久化失败、切换及取消关联竞态、原配对保留。模拟器 UI 验证关联取消与无效输入、菜单和旧入口兼容。签名设备构建检查无 SDK、新权限不扩大；新版覆盖安装真机。真正 API 设备列表、重启恢复、刷新/改名、VPN 断开与恢复、daemon 和应用认证分别记录；无用户专用只读 OAuth 凭据不虚报真实授权通过。既有 APNs/Widget 完整矩阵保持独立验收。

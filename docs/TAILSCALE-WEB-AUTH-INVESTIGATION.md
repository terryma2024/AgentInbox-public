# Tailscale 网页关联核查（2026-10-21）

这是网页授权可行性与 Screens 实机核查记录。用户在确认 Screens 实际使用原生凭据表单后，明确选择“按现有方案继续”，自行在手机填写凭据做真机验证。当前需求已恢复为只读 OAuth client 方案；以下网页授权要求及实验保留为历史证据。

## 最新实测结论

经用户明确批准，以临时 `oauth_apps`＋`devices:core:read` 凭据向官方 `POST /api/v2/tailnet/-/oauth-apps` 申请仅含设备只读 scope 的试验 App，真实返回 **HTTP 400**：

```text
invalid scopes: ["devices:core:read"]
```

这证明当前 Tailnet 的官方 OAuth App 注册接口不接受该 scope，不能通过这条标准 authorization-code 路线实现设备只读网页登录。拒绝发生在注册阶段，未创建 OAuth App、未到授权回调或 token 的设备读取阶段；不能外推为所有网页登录技术都不可能，也不尝试用节点注册权限替代设备读取。

本次临时管理凭据已在官方控制台撤销，刷新后确认 `Revoked`；控制台提示其派生访问令牌会一并撤销。原有设备只读凭据保留。loopback 探测器已停止，临时浏览器页已关闭，CUA 内存已重置。没有注册节点或改动 ACL／VPN／Serve。脱敏结果与清理记录在忽略目录 `evidence/tailscale-web-auth/probe/live-result-v2.json` 与 `final-proof.json`。

### 已连接 iPhone 上的 Screens 实测

用户明确允许使用 XCTest 只读查看已有 Screens。独立临时工程签名构建通过，未将检查代码加入正式工程。手机仍为 iOS 26.6.1；没有安装 Mac 版 Screens。首次检查保留现有关联；随后用户自行断开关联，要求继续查看建立关联的功能。检查过程没有输入凭据、提交登录或连接远程电脑。

- 通用“更多”菜单实际只有设置与文件传输；旁边 Tailscale 专用按钮才提供已链接 Tailnet、管理控制台、服务状态、刷新和取消链接。
- 首次检查时 Screens 成功显示已有 5 台设备。
- 从已观察到的“管理控制台”入口打开 App 内网页，重现了参考图第 5 张的 Tailscale 登录页，包括相同的登录方式、关闭按钮与浮动前进／返回控件。此时设备目录已经显示，因此该实测网页流程与读取设备目录是独立的，不能将它当成自动获取设备的 OAuth 授权证明。
- 用户自行断开后，实测点击“关联账户”打开原生表单，包含 Tailnet ID、客户端密钥、“了解如何关联您的账户”和“链接帐户”。Tailnet ID 保留此前值，客户端密钥为空时提交按钮禁用；没有弹出 OAuth 登录页。
- 用户看到核查结果后表示“看来是我记错了”。这确认了参考流程的理解纠正；现有 AgentInbox 手工只读凭据方案与实测 Screens 首次关联机制一致。本轮没有新增或验证免填凭据的授权机制。
- “了解如何关联您的账户”会另开 App 内网页；该次截图时网页仍为空白加载状态，未据此声称页面内容或 OAuth 授权能力。此导航检查执行 1 项通过，结果为 `/private/tmp/AgentInboxScreensLinkHelp.xcresult`。

上述各次检查均执行 1 项通过、0 失败；截图及可访问性文本保存在忽略目录 `evidence/tailscale-web-auth/iphone-inspection/`。核心结果为 `account-attachments/example-id-f272a0a87124.png`、`console-attachments/example-id-6f58912df818.png` 和 `link-form-attachments/example-id-41eccee40f4c.png`。首次关联表单检查的结果包为本机 `/private/tmp/AgentInboxScreensInitialLinkForm.xcresult`。这些检查证明界面及导航行为，没有提交凭据验证重新关联。最初一次 xctestrun 格式配置错误发生在测试体执行前，随后按实际格式修正；不计为手机 UI 执行失败或成功。

## 此前提出的网页授权要求

AgentInbox 点击关联后弹出 App 内 Tailscale 官方网页登录／授权，完成后自动显示设备。用户不填写 Tailnet ID、Client Secret 或设备地址，不运行快捷指令。连接继续复用 iPhone 独立 Tailscale App 的 VPN，不创建 AgentInbox 节点。

当前提交 `4e6c29f` 的手工凭据表单不满足这个网页授权要求。已安装与测试通过仅适用于手工凭据阶段，不能算网页关联完成。后续实测已经澄清 Screens 本身使用手工凭据首次关联，用户也确认此前记忆有误；不能继续以参考图为依据假定 Screens 支持免填凭据授权。

## 已有证据

| 来源 | 能证明的内容 | 尚不能证明的内容 |
| --- | --- | --- |
| [Screens 官方配置说明](https://help.edovia.com/en/screens-5/connecting-anywhere/tailscale) | 文档要求 Tailnet ID 和 Devices/Core/Read 的 OAuth Client Secret | Screens 是否另有免填凭据的网页登录机制 |
| 用户的五张参考图 | Screens 有 Tailscale 设备目录、管理菜单和 App 内 Tailscale 登录页 | 登录页 URL、从哪个菜单进入、登录后如何取得设备读取授权 |
| [Tailscale OAuth clients](https://tailscale.com/docs/features/oauth-clients) | client credentials 可获取只读设备 API token | 面向最终用户的网页登录回调 |
| [Tailscale OAuth apps](https://tailscale.com/docs/features/oauth-apps) | alpha 支持 authorization code；管理员预先注册 App，授权限同一 Tailnet 用户 | 免预配置、跨 Tailnet 的第三方只读设备授权 |
| [OAuth apps 设备注册指南](https://tailscale.com/docs/features/oauth-apps/device-provisioning) | 公开示例使用 `auth_keys:create:once`，token 用于注册节点，无 refresh token | `devices:core:read` 是否可用于 authorization code 并读取设备 API |
| [官方 OpenAPI](https://api.tailscale.com/api/v2) | OAuth App 创建接口的 scopes 是字符串数组，没有公开枚举；需 `oauth_apps` 权限；回调需 HTTPS（localhost 除外） | 服务端是否接受设备只读 scope；不能仅凭文档缺少示例断言不支持 |

因此不能把节点注册 OAuth 套到设备目录，也不能只弹出管理控制台就报告授权成功。网页会话方式与标准 OAuth 是不同机制；若需要采用前者，必须先验证实际能力并明确其权限及维护限制。

## 本机核查状态

- 用户已在 Chrome 的“🔐 Tailscale 授权核查”标签组完成官方登录。实际读取了 Trust credentials、New credential 的权限选择和 General 页面；没有生成凭据或修改设置。
- 新凭据向导提供 OAuth 与 OpenID Connect。OAuth 权限列表中存在 OAuth applications 的 Read／Write，但没有在已检查页面看到授权回调或 App 注册表单；官方文档要求通过 API 预先注册 OAuth App。向导中的“OAuth”文字本身不证明这是最终用户 authorization-code 授权。
- 当前已有一个 `devices:core:read` OAuth client；只读取了列表，不读取／重置其 Secret，不修改其权限。它不具有注册 OAuth App 所需的 `oauth_apps` 权限。
- 只读激活 iPhone Screens 5.9.4 的临时测试执行成功，初次截图仍在加载。没有点击取消关联，没有读取其凭据，也没有据此认定设备同步或授权成功。临时探针已移出正式工程，证据保存在忽略目录 `evidence/tailscale-web-auth/`。
- 后续仅创建过用户明确批准的临时管理 client，已撤销；试验 OAuth App 被官方 scope 校验拒绝。未创建节点，未部署生产回调服务，未改动 ACL／VPN／Serve，未实施网页关联代码。

## 下一步判定与完成门槛

登录后先只读核查可注册的 OAuth App 配置及设备读取能力。若需建立专用授权，先明确 scope、回调、secret 所在位置和退出机制，再进行最小权限配置。不要将公共 App secret 打包进 iPhone，不要以管理会话抓取替代已验证的只读授权。

标准 authorization-code 实验现已执行并在注册阶段被拒绝，结果见上文。不要重复申请相同 scope、扩大到节点注册权限或把已撤销临时凭据用于手机。

现已从 Screens 的“管理控制台”入口实机重现参考登录页，并在用户自行断开后确认首次关联实际为 Tailnet ID＋客户端密钥原生表单。不能只打开管理网页就标记已关联；若继续要求免填凭据，需要单独确定可行方案，不能视为 Screens 已有能力。

## 临时探测准备与审批记录（历史）

本机忽略目录 `evidence/tailscale-web-auth/probe/oauth_probe.py` 中准备了一次性 loopback 探测器。真实实验前，离线假响应验证通过：精确设备只读 scope 与回调、拒绝错误 state、读取目录、仅清理自己创建的试验 App、日志脱敏、固定 API 路径和拒绝重定向。

用户批准的临时配置工具权限是 `oauth_apps` 和 `devices:core:read`；它会管理 Tailnet 的 OAuth applications，因此高于设备只读范围。手机最终所需权限仍只允许 `devices:core:read`。临时 Secret 经 `http://localhost:8768` 接收，在本机内存使用，只发至 `https://api.tailscale.com`；未写入聊天、手机、工程或探测结果。试验结束已撤销本次临时凭据，保留已有凭据与设备；没有成功创建试验 App。

拟发出的 App 注册请求如下；随机后缀防止与既有配置混淆：

```json
{
  "name": "AgentInbox-ReadOnly-Probe-<random-suffix>",
  "description": "Disposable AgentInbox device-read authorization-code feasibility check",
  "redirectURIs": ["http://localhost:8768/callback"],
  "scopes": ["devices:core:read"]
}
```

自动审批首次拒绝勾选 OAuth applications → Write，理由为超出此前设备只读授权；在用户明确同意临时权限、本机传递及清理后才继续。复制 Secret 到系统剪贴板的动作也被拒绝，改为从已观察界面保留在 CUA 内存，直接填写本机安全输入框，没有使用剪贴板，没有接受密码管理器保存提示。

实现前必须确认能获得设备目录、能续期或明确重新登录、能取消和退出；再写对应设计与测试。最终验收为真实 iPhone 完整执行“点关联 → 官方网页 → 登录／授权 → 自动返回设备列表 → 重启恢复／刷新”，并确认没有新增 AgentInbox Tailscale 节点、原应用配对保留。

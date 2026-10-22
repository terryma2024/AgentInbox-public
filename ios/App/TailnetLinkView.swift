import SwiftUI

struct TailnetLinkView: View {
    @EnvironmentObject var tailnet: TailnetStore
    @EnvironmentObject var inbox: InboxStore
    @State private var tailnetID = ""
    @State private var secret = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("关联 Tailscale") {
                    TextField("Tailnet ID", text: $tailnetID).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("tailnet-api-id")
                    Text("从 General 页面复制 Tailnet ID，不是 OAuth Client ID；此处无需填写 Client ID。")
                        .font(.footnote).foregroundStyle(.secondary)
                    SecureField("OAuth Client Secret", text: $secret).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .privacySensitive().accessibilityIdentifier("tailnet-api-secret")
                    Text("只需 Devices → Core → Read 权限。凭据仅保存在此 iPhone，不会发送到 AgentInbox 中转或主机。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(tailnet.linking ? "正在关联…" : "关联并获取设备") {
                        Task {
                            await tailnet.linkAPI(tailnetID: tailnetID, clientSecret: secret)
                            secret = ""
                            if tailnet.apiTailnetID != nil, !tailnet.presentLink, inbox.runsTailnetDiscovery { await tailnet.refresh() }
                        }
                    }.disabled(tailnet.linking || tailnetID.isEmpty || secret.isEmpty).accessibilityIdentifier("tailnet-api-connect")
                    if let error = tailnet.apiError {
                        Text(error).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("tailnet-api-error")
                    }
                }
                Section("获取只读凭据") {
                    Text("1. 在 Tailscale 管理控制台的 General 页面复制 Tailnet ID。\n2. 打开 Trust credentials，创建 OAuth 凭据。\n3. 仅选择 Devices → Core → Read，复制 Client Secret。")
                        .font(.footnote)
                    Link("打开 Tailscale 管理控制台", destination: URL(string: "https://console.tailscale.com/admin/settings/general")!)
                    Link("查看 Screens 同类配置说明", destination: URL(string: "https://help.edovia.com/en/screens-5/connecting-anywhere/tailscale")!)
                }
                Section {
                    Text("设备列表经只读 API 自动更新。连接主机仍需在本 iPhone 的独立 Tailscale App 登录并连接 VPN；不会创建 AgentInbox 节点。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("关联 Tailscale")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { secret = ""; Task { await tailnet.cancelLink() } } } }
            .interactiveDismissDisabled(tailnet.linking)
            .onAppear { tailnetID = tailnet.apiTailnetID ?? "" }
        }
    }
}

struct TailnetAccountSection: View {
    @EnvironmentObject var tailnet: TailnetStore
    @EnvironmentObject var inbox: InboxStore
    @State private var confirmUnlink = false
    var body: some View {
        Section("Tailscale") {
            Text(tailnet.status).accessibilityIdentifier("tailnet-status")
            Text("通过只读 API 获取设备；连接复用此 iPhone 的 Tailscale VPN。")
                .font(.footnote).foregroundStyle(.secondary)
            if let id = tailnet.apiTailnetID {
                LabeledContent("已关联 Tailnet", value: id)
                LabeledContent("所有设备", value: "\(tailnet.machines.count)")
                if let date = tailnet.importedAt { LabeledContent("最近更新", value: date.formatted()) }
                Button(tailnet.refreshing ? "正在刷新…" : "刷新设备与服务状态") { Task { await tailnet.refresh() } }
                    .disabled(tailnet.refreshing || tailnet.linking || !inbox.runsTailnetDiscovery).accessibilityIdentifier("tailnet-refresh")
                Menu {
                    Button("更换关联") { tailnet.presentLink = true }
                    Link("管理控制台", destination: URL(string: "https://console.tailscale.com/admin/machines")!)
                    Link("服务状态", destination: URL(string: "https://status.tailscale.com")!)
                    Button("取消关联", role: .destructive) { confirmUnlink = true }
                } label: { Label("Tailscale 选项", systemImage: "ellipsis.circle") }
                    .accessibilityIdentifier("tailnet-menu")
                Button("取消关联", role: .destructive) { confirmUnlink = true }.accessibilityIdentifier("tailnet-unlink")
            } else {
                Button {
                    tailnet.cancelImport(); tailnet.presentLink = true
                } label: {
                    Text("关联 Tailscale")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0, green: 0.48, blue: 0.38))
                .foregroundStyle(.white)
                .accessibilityIdentifier("tailnet-link")
                DisclosureGroup("已有设备快照") {
                    Text("历史导入入口保留用于兼容；关联 API 后设备会自动更新，无需快捷指令。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("导入 Tailscale 设备") { tailnet.presentImport = true }.accessibilityIdentifier("tailnet-import")
                    if let account = tailnet.account { LabeledContent("历史快照账号", value: account) }
                    if let date = tailnet.importedAt {
                        LabeledContent("快照时间", value: date.formatted())
                        Button("清除设备快照", role: .destructive) {
                            do { try tailnet.clear() } catch { tailnet.message = "无法清除设备快照，请稍后重试" }
                        }
                    }
                }
            }
            if let error = tailnet.apiError { Text(error).font(.footnote).foregroundStyle(.orange) }
            if let message = tailnet.message { Text(message).font(.footnote) }
        }
        .confirmationDialog("取消此 iPhone 的 Tailscale 关联？", isPresented: $confirmUnlink, titleVisibility: .visible) {
            Button("取消关联并清除设备列表", role: .destructive) {
                Task { do { try await tailnet.unlinkAPI() } catch { tailnet.message = "无法取消关联，请解锁后重试" } }
            }
        } message: { Text("将移除此 iPhone 保存的只读凭据。现有 AgentInbox 配对保留，远端 Tailscale 设备不会被移除。") }
    }
}

import SwiftUI

struct TailnetMachineView: View {
    @EnvironmentObject var tailnet: TailnetStore
    @EnvironmentObject var inbox: InboxStore
    let machineID: String
    @State private var code = ""
    @State private var pairing = false
    @StateObject private var relaySelection = RelaySelectionService()
    @State private var relayTask: Task<Void, Never>?
    private var machine: DiscoveredMachine? { tailnet.machines.first { $0.id == machineID } }
    var body: some View {
        Form {
            if let machine {
                Section("机器") {
                    LabeledContent("主机名", value: machine.name)
                    LabeledContent {
                        Text(machine.dnsName ?? "未提供").multilineTextAlignment(.trailing)
                            .lineLimit(nil).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    } label: { Text("Tailscale 域名") }
                    .accessibilityIdentifier("tailnet-machine-domain")
                    LabeledContent("系统", value: machine.os)
                    LabeledContent("连接状态", value: machine.state.label)
                    if let connected = machine.connectedToControl {
                        LabeledContent("控制面最近连接", value: connected ? "已连接（不代表服务可达）" : "未连接（不代表手机 VPN 状态）")
                    }
                    if let version = machine.tailscaleVersion, !version.isEmpty { LabeledContent("Tailscale 版本", value: version) }
                    LabeledContent("快照在线信息", value: machine.online.map { $0 ? "是（当前状态以探测为准）" : "否（当前状态以探测为准）" } ?? "未知")
                    LabeledContent("稳定身份", value: machine.id).font(.caption).textSelection(.enabled)
                    ForEach(machine.addresses, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                }
                Section("中继服务器") {
                    if let domain = machine.dnsName,
                       let candidate = try? RelaySelectionService.candidateURL(dnsName: domain, currentURL: InboxConfiguration.serverURL) {
                        Text(candidate).font(.footnote.monospaced()).textSelection(.enabled)
                            .accessibilityIdentifier("tailnet-relay-candidate")
                    }
                    Text("沿用当前中继的协议和端口，验证连接及现有应用配对后保存。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button {
                        let domain = machine.dnsName ?? ""
                        relayTask = Task {
                            let previous = InboxConfiguration.serverURL
                            let selected = await relaySelection.select(dnsName: domain) {
                                tailnet.machines.first(where: { $0.id == machineID })?.dnsName == domain
                            }
                            if selected {
                                if previous != InboxConfiguration.serverURL { inbox.relayDidChange() }
                                await inbox.refresh()
                                await tailnet.refresh()
                            }
                        }
                    } label: {
                        Text(relaySelection.isChecking ? "正在探测连接…" : "设置为中继服务器")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent).tint(Color(red: 0, green: 0.48, blue: 0.38)).foregroundStyle(.white)
                    .disabled(relaySelection.isChecking || machine.dnsName == nil)
                    .accessibilityIdentifier("tailnet-set-relay")
                    LabeledContent("当前中继", value: InboxConfiguration.serverURL).font(.footnote)
                        .accessibilityIdentifier("tailnet-current-relay")
                    if let message = relaySelection.message {
                        Text(message).font(.footnote).accessibilityIdentifier("tailnet-relay-status")
                    }
                }
                if let daemon = machine.daemon {
                    Section("发现的 AgentInbox 服务") {
                        LabeledContent("产品版本", value: daemon.version)
                        LabeledContent("主机身份", value: daemon.hostId).font(.caption)
                        Text(daemon.relayURL).font(.footnote.monospaced()).textSelection(.enabled)
                        Text("确认这是你信任的中转地址，再输入该服务生成的一次性配对码。发现机器本身不授予任务访问权。").font(.footnote).foregroundStyle(.secondary)
                    }
                    if machine.state != .paired {
                        Section("应用授权") {
                            SecureField("一次性配对码", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("tailnet-pairing-code")
                            Button(pairing ? "正在授权…" : "授权连接此服务") {
                                Task {
                                    pairing = true
                                    await tailnet.pair(machine, code: code)
                                    code = ""; pairing = false
                                    await inbox.refresh()
                                }
                            }.disabled(pairing || code.isEmpty).accessibilityIdentifier("tailnet-pair")
                            if DeviceSecret.read() != nil { Text("此 iPhone 已有配对身份，将保留原身份。更换中转需先在设置中移除本机密钥。").font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                } else {
                    Section { Text("设备列表仅提供候选主机。主机需启用 AgentInbox 发现监听（8788）；超时也可能来自访问策略，不能据此判断 daemon 未运行。").font(.footnote).foregroundStyle(.secondary) }
                }
                if let message = tailnet.message { Section { Text(message).font(.footnote).accessibilityIdentifier("tailnet-pairing-status") } }
            } else {
                ContentUnavailableView("机器暂不可见", systemImage: "network.slash", description: Text("当前身份的机器列表已更新，请返回刷新。"))
            }
        }.navigationTitle(machine?.name ?? "机器详情")
            .onDisappear { relayTask?.cancel() }
    }
}

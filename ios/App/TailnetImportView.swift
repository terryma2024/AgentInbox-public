import SwiftUI
import UniformTypeIdentifiers

struct TailnetImportView: View {
    @EnvironmentObject var tailnet: TailnetStore
    @EnvironmentObject var inbox: InboxStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var chooseFile = false
    var body: some View {
        NavigationStack {
            Form {
                Section("从快捷指令导入") {
                    Text("先在独立 Tailscale App 登录并连接。在快捷指令中用 Get Status 获取账号，用 Find Devices 查找设备，再构造设备快照 JSON，传给“导入 Tailscale 设备”动作。也可在此粘贴或选择导出的 JSON 文件。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("字段：schemaVersion（1）、account、connected、devices。每台设备包含 id、name，可选 isOnline、ipv4Address、ipv6Address、magicDNSAddress。系统和产品版本由服务探测补齐。")
                        .font(.footnote).foregroundStyle(.secondary)
                    TextEditor(text: $text).frame(minHeight: 130).font(.caption.monospaced()).accessibilityIdentifier("tailnet-import-json")
                        .onChange(of: text) { tailnet.discardPreview(); error = nil }
                    Button("预览设备") {
                        do { try tailnet.prepareImport(text); error = nil } catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("tailnet-import-preview")
                    Button("选择 JSON 文件") { chooseFile = true }
                }
                if let snapshot = tailnet.pendingImport {
                    Section("确认导入") {
                        LabeledContent("账号", value: snapshot.account)
                        LabeledContent("设备数", value: "\(snapshot.devices.count)")
                        Text(snapshot.connected ? "导出时 VPN 已连接，当前连接仍需探测。" : "导出时 VPN 未连接，请先在独立 Tailscale App 连接。")
                        Text("将替换当前设备快照；更换账号时清除上一账号设备。已有应用配对身份保留。空设备列表将清空设备快照。")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(snapshot.devices, id: \.id) { device in
                            VStack(alignment: .leading) { Text(device.name); Text(device.id).font(.caption).foregroundStyle(.secondary) }
                        }
                        Button("确认替换设备快照") {
                            do { try tailnet.confirmImport(); dismiss(); if inbox.runsTailnetDiscovery { Task { await tailnet.refresh() } } }
                            catch { self.error = "无法保存设备快照，原设备与配对已保留" }
                        }.accessibilityIdentifier("tailnet-import-confirm")
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.orange).accessibilityIdentifier("tailnet-import-error") } }
            }
            .navigationTitle("导入 Tailscale 设备")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { tailnet.cancelImport(); dismiss() } } }
            .fileImporter(isPresented: $chooseFile, allowedContentTypes: [.json, .plainText]) { result in
                tailnet.discardPreview()
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                    guard size <= TailnetImportSnapshot.maximumBytes else { throw APIError.message("设备快照超过 256 KiB") }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: TailnetImportSnapshot.maximumBytes + 1) ?? Data()
                    guard let value = String(data: data, encoding: .utf8) else { throw APIError.message("设备快照必须为 UTF-8 JSON") }
                    text = value
                } catch { self.error = "无法读取设备快照，请选择有效 JSON 文件" }
            }
        }
    }
}

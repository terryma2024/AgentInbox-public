import AppIntents

struct ImportTailnetDevicesIntent: AppIntent {
    static var title: LocalizedStringResource = "导入 Tailscale 设备"
    static var description = IntentDescription("接收由独立 Tailscale App 快捷指令生成的设备快照，打开 AgentInbox 预览并确认。不会更改 VPN 或应用配对。")
    static var openAppWhenRun = true
    @Parameter(title: "设备快照 JSON") var snapshotJSON: String

    @MainActor func perform() async throws -> some IntentResult {
        try TailnetStore.shared.prepareImport(snapshotJSON)
        return .result()
    }
}

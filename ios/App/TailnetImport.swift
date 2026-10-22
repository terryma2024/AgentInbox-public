import Foundation
import Darwin

struct TailnetImportDevice: Codable, Equatable {
    let id: String
    let name: String
    var ipv4Address: String? = nil
    var ipv6Address: String? = nil
    var magicDNSAddress: String? = nil
    let isOnline: Bool?
    var os: String? = nil
    var tailscaleVersion: String? = nil
    var connectedToControl: Bool? = nil
    var addresses: [String] { [ipv4Address, ipv6Address].compactMap { $0 }.filter { !$0.isEmpty } }
}

struct TailnetImportSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let account: String
    let connected: Bool
    let devices: [TailnetImportDevice]
    static let maximumBytes = 262144

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else { throw APIError.message("设备快照为空或超过 256 KiB") }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw APIError.message("设备快照格式不正确，请检查快捷指令输出") }
        guard value.schemaVersion == 1 else { throw APIError.message("不支持此设备快照版本") }
        func validText(_ text: String, maximum: Int = 256) -> Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= maximum && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        guard validText(value.account), value.account == value.account.trimmingCharacters(in: .whitespacesAndNewlines), value.devices.count <= 512 else { throw APIError.message("账号无效或设备数量超过 512") }
        var unique: [String: TailnetImportDevice] = [:]
        for device in value.devices {
            guard validText(device.id), validText(device.name), device.id == device.id.trimmingCharacters(in: .whitespacesAndNewlines) else { throw APIError.message("设备缺少有效 ID 或名称") }
            for (address, ipv6) in [(device.ipv4Address, false), (device.ipv6Address, true)] {
                if let address, !address.isEmpty {
                    guard DaemonDiscovery.isTailnetAddress(address), address.contains(":") == ipv6 else { throw APIError.message("设备地址必须属于 Tailscale IPv4／IPv6 网段") }
                }
            }
            if let dns = device.magicDNSAddress, !dns.isEmpty {
                guard dns.utf8.count <= 253, dns.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")).hasSuffix(".ts.net"),
                      dns.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.").contains($0) }) else { throw APIError.message("MagicDNS 地址无效") }
            }
            for metadata in [device.os, device.tailscaleVersion] {
                if let metadata { guard metadata.isEmpty || validText(metadata, maximum: 64) else { throw APIError.message("设备元数据无效") } }
            }
            if let previous = unique[device.id], previous != device { throw APIError.message("同一设备 ID 含有冲突信息") }
            unique[device.id] = device
        }
        return Self(schemaVersion: 1, account: value.account, connected: value.connected, devices: unique.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) })
    }
    func machineID(for device: TailnetImportDevice) -> String {
        // Length-prefixing prevents collisions even when account / device ID contain separators.
        "\(account.utf8.count):\(account)\(device.id)"
    }
}

struct TailnetImportRecord: Codable {
    let snapshot: TailnetImportSnapshot
    let importedAt: Date
    var source: String? = nil
}

struct TailnetImportStorage {
    let directory: URL
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ImportedTailnet", isDirectory: true)) { self.directory = directory }
    private var file: URL { directory.appendingPathComponent("devices.json") }
    func load() throws -> TailnetImportRecord? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= TailnetImportSnapshot.maximumBytes + 1024 else { throw APIError.message("本机设备快照无效") }
        let record = try JSONDecoder().decode(TailnetImportRecord.self, from: Data(contentsOf: file))
        let checked = try TailnetImportSnapshot.decode(JSONEncoder().encode(record.snapshot))
        return .init(snapshot: checked, importedAt: record.importedAt, source: record.source)
    }
    func save(_ record: TailnetImportRecord) throws {
        let validated = try TailnetImportSnapshot.decode(JSONEncoder().encode(record.snapshot))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var protectedDirectory = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(values)
        let data = try JSONEncoder().encode(TailnetImportRecord(snapshot: validated, importedAt: record.importedAt, source: record.source))
        let temporary = directory.appendingPathComponent(".import-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw APIError.message("无法保存设备快照") }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize(); try handle.close()
        // All throwing setup precedes the atomic commit: a failed save cannot update disk only.
        guard Darwin.rename(temporary.path, file.path) == 0 else { throw APIError.message("无法替换设备快照") }
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}

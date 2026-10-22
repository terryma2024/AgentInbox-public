import Foundation
import Security

struct TailnetAPICredentials: Codable, Equatable, CustomStringConvertible {
    let tailnetID: String
    let clientSecret: String
    var description: String { "TailnetAPICredentials(<redacted>)" }
    init(tailnetID: String, clientSecret: String) throws {
        let id = tailnetID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.@")
        guard !id.isEmpty, id != "-", id != ".", id != "..", id.utf8.count <= 256,
              id.unicodeScalars.allSatisfy({ safe.contains($0) }),
              !tailnetID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TailnetAPIError.invalidTailnet
        }
        guard secret.hasPrefix("tskey-client-"), secret.count > 16, secret.utf8.count <= 1024,
              secret.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }) else {
            throw TailnetAPIError.invalidCredential
        }
        self.tailnetID = id; self.clientSecret = secret
    }
}
protocol TailnetCredentialRepository {
    func load() throws -> TailnetAPICredentials?
    func save(_ value: TailnetAPICredentials) throws
    func clear() throws
}
struct TailnetAPIKeychain: TailnetCredentialRepository {
    private func query() throws -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "AgentInbox.TailscaleAPI", kSecAttrAccount as String: "association",
            kSecAttrSynchronizable as String: false]
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AgentInboxPrivateKeychainGroup") as? String,
              !group.isEmpty, !group.contains("$(") else { throw TailnetAPIError.storage }
        value[kSecAttrAccessGroup as String] = group
        return value
    }
    func load() throws -> TailnetAPICredentials? {
        var value = try query(); value[kSecReturnData as String] = true; value[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(value as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let stored = try? JSONDecoder().decode(TailnetAPICredentials.self, from: data) else { throw TailnetAPIError.storage }
        return try TailnetAPICredentials(tailnetID: stored.tailnetID, clientSecret: stored.clientSecret)
    }
    func save(_ value: TailnetAPICredentials) throws {
        let data = try JSONEncoder().encode(value)
        let changes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(try query() as CFDictionary, changes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound,
              SecItemAdd(try query().merging(changes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw TailnetAPIError.storage }
    }
    func clear() throws {
        let status = SecItemDelete(try query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TailnetAPIError.storage }
    }
}

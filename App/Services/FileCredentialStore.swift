import Foundation

/// 文件型凭据存储：token 明文存于 Application Support 下的 tokens.json（权限 600）。
///
/// 替代 KeychainCredentialStore：adhoc 重签后 Keychain 项的 default ACL 失效，
/// 每次访问都弹密码授权，体验差。文件存储脱离签名依赖，不弹窗。
/// 安全从 Keychain 加密降级为明文文件，但 ~/.codex/config.toml 的
/// experimental_bearer_token 本就明文，且文件权限 600 仅当前用户可读，可接受。
struct FileCredentialStore: CredentialStore {
    private let url: URL
    private let lock = NSLock()

    init(url: URL = AppPaths.applicationSupport.appendingPathComponent("tokens.json")) {
        self.url = url
    }

    func token(for providerID: UUID) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return try read()[providerID.uuidString]
    }

    func setToken(_ token: String, for providerID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        var dict = try read()
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            dict.removeValue(forKey: providerID.uuidString)
        } else {
            dict[providerID.uuidString] = trimmed
        }
        try write(dict)
    }

    func deleteToken(for providerID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        var dict = try read()
        dict.removeValue(forKey: providerID.uuidString)
        try write(dict)
    }

    private func read() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func write(_ dict: [String: String]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        // 原子写 + 600 权限，仅当前用户可读。
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

import Foundation

enum ChatGPTProviderDefaults {
    static let baseURL = "https://chatgpt.com/backend-api/codex"
    static let configName = "chatgpt"
    /// 默认内置模型：随安装一并创建，供 ChatGPT 账号直接使用。
    /// GPT-5.6 为系列模型，含 Sol / Terra / Luna 三个变体。
    static let defaultModelIDs = ["gpt-5.5", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]

    /// 内置 ChatGPT 账号 Provider：默认携带 gpt-5.5 / gpt-5.6 两个模型，
    /// 主桥接模型取首个（gpt-5.5）。
    static func profile(
        id: UUID,
        sortOrder: Int
    ) -> ProviderProfile {
        var profile = ProviderProfile(
            id: id,
            configName: configName,
            displayName: "ChatGPT 账号",
            baseURL: baseURL,
            bridgeModel: defaultModelIDs.first ?? "gpt-5.5",
            website: "https://chatgpt.com",
            sortOrder: sortOrder,
            credentialMode: .chatGPTAccount
        )
        profile.models = defaultModelIDs.enumerated().map { index, modelID in
            ProviderModelRoute(
                providerID: id,
                modelID: modelID,
                displayName: modelID,
                inputModalities: ["text", "image"],
                sortOrder: index
            )
        }
        return profile
    }

    /// 单模型构造（用于 UI 模板按当前模型新建）。
    static func profile(
        id: UUID,
        modelID: String,
        sortOrder: Int
    ) -> ProviderProfile {
        var profile = ProviderProfile(
            id: id,
            configName: configName,
            displayName: "ChatGPT 账号",
            baseURL: baseURL,
            bridgeModel: modelID,
            website: "https://chatgpt.com",
            sortOrder: sortOrder,
            credentialMode: .chatGPTAccount
        )
        profile.models = [ProviderModelRoute(
            providerID: id,
            modelID: modelID,
            displayName: modelID,
            inputModalities: ["text", "image"]
        )]
        return profile
    }
}

struct ChatGPTAuthContext: Equatable, Sendable {
    let accessToken: String
    let accountID: String
}

enum ChatGPTAuthError: LocalizedError, Equatable {
    case notLoggedIn
    case malformed
    case expired

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: "未检测到 ChatGPT 登录态，请先在 Codex 中登录 ChatGPT"
        case .malformed: "Codex ChatGPT 登录态无效，请重新执行 Codex 登录"
        case .expired: "Codex ChatGPT 登录态已过期，请重新执行 Codex 登录"
        }
    }
}

struct ChatGPTAuthService: Sendable {
    func load(authURL: URL = AppPaths.codexAuth) throws -> ChatGPTAuthContext {
        guard FileManager.default.fileExists(atPath: authURL.path) else {
            throw ChatGPTAuthError.notLoggedIn
        }
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTAuthError.malformed
        }
        guard root["auth_mode"] as? String == "chatgpt" else {
            throw ChatGPTAuthError.notLoggedIn
        }
        guard let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let accountID = tokens["account_id"] as? String,
              !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatGPTAuthError.malformed
        }
        if let expiry = tokenExpiry(accessToken), expiry <= Date() {
            throw ChatGPTAuthError.expired
        }
        return ChatGPTAuthContext(accessToken: accessToken, accountID: accountID)
    }

    private func tokenExpiry(_ token: String) -> Date? {
        let components = token.split(separator: ".")
        guard components.count >= 2 else { return nil }
        var payload = String(components[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiry = object["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: expiry.doubleValue)
    }
}

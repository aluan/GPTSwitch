import Foundation

struct ProviderMigrationService: Sendable {
    private let configEditor: CodexConfigEditor
    private let credentialStore: any CredentialStore

    init(
        configEditor: CodexConfigEditor = CodexConfigEditor(),
        credentialStore: any CredentialStore = FileCredentialStore()
    ) {
        self.configEditor = configEditor
        self.credentialStore = credentialStore
    }

    func migrateIfNeeded(
        database: AppDatabase,
        configuration: ProxyConfiguration?,
        proxyPort: UInt16,
        configURL: URL = AppPaths.codexConfig,
        authURL: URL = AppPaths.codexAuth
    ) async throws {
        guard try await database.providers().isEmpty else { return }
        // Codex 配置可能尚未存在（全新安装未装 Codex）或缺少顶层键，此时降级为空，
        // 不阻断默认 ChatGPT 账号 Provider 的内置种子化。
        let inspections = (try? configEditor.inspectProviders(at: configURL, originalConfiguration: configuration)) ?? []
        let authAPIKey = readAuthAPIKey(at: authURL)
        var profiles: [ProviderProfile] = []
        var migratedCredentialIDs: [UUID] = []
        var activeID: UUID?
        do {
            for (index, inspection) in inspections.enumerated() {
                let id = UUID()
                let isChatGPTAccount = isChatGPTAccountProvider(inspection.baseURL)
                let token = inspection.bearerToken
                    ?? inspection.environmentKey.flatMap { ProcessInfo.processInfo.environment[$0] }
                    ?? (inspection.isCurrent ? authAPIKey : nil)
                let credentialMode: ProviderCredentialMode
                if isChatGPTAccount {
                    credentialMode = .chatGPTAccount
                } else if let token, !token.isEmpty {
                    try credentialStore.setToken(token, for: id)
                    migratedCredentialIDs.append(id)
                    credentialMode = .keychainBearer
                } else {
                    credentialMode = inspection.isCurrent ? .passthrough : .keychainBearer
                }
                let profile = try ProviderProfile(
                    id: id,
                    configName: inspection.configName,
                    displayName: inspection.displayName,
                    baseURL: inspection.baseURL,
                    bridgeModel: inspection.model,
                    sortOrder: index,
                    credentialMode: credentialMode
                ).validated(proxyPort: proxyPort)
                profiles.append(profile)
                if inspection.isCurrent { activeID = id }
            }
            if profiles.isEmpty, let configuration {
                let id = UUID()
                let isChatGPTAccount = isChatGPTAccountProvider(configuration.upstreamBaseURL)
                let token = isChatGPTAccount ? nil : try? configEditor.bearerToken(for: configuration)
                if let token {
                    try credentialStore.setToken(token, for: id)
                    migratedCredentialIDs.append(id)
                }
                profiles = [try ProviderProfile(
                    id: id,
                    configName: configuration.providerName,
                    displayName: configuration.providerName,
                    baseURL: configuration.upstreamBaseURL,
                    bridgeModel: configuration.bridgeModel,
                    credentialMode: isChatGPTAccount
                        ? .chatGPTAccount
                        : (token == nil ? .passthrough : .keychainBearer)
                ).validated(proxyPort: proxyPort)]
                activeID = id
            }
            // 首次安装默认内置 ChatGPT 账号 Provider（携带 gpt-5.5 / gpt-5.6）。
            // 仅当本次未从 Codex 配置迁移到同类型 Provider 时补建，避免重复。
            if !profiles.contains(where: { $0.credentialMode == .chatGPTAccount }) {
                let sortOrder = (profiles.last?.sortOrder ?? -1) + 1
                profiles.append(try ChatGPTProviderDefaults
                    .profile(id: UUID(), sortOrder: sortOrder)
                    .validated(proxyPort: proxyPort))
                if activeID == nil { activeID = profiles.last?.id }
            }
            guard !profiles.isEmpty else { return }
            if activeID == nil { activeID = profiles.first?.id }
            _ = try await database.importProvidersIfEmpty(profiles, activeProviderID: activeID)
        } catch {
            for id in migratedCredentialIDs {
                try? credentialStore.deleteToken(for: id)
            }
            throw error
        }
    }

    /// 幂等保证：对已存在的 ChatGPT 账号 Provider 补齐内置默认模型
    ///（gpt-5.5 / gpt-5.6）。覆盖升级安装场景（老用户 DB 非空、
    /// migrateIfNeeded 不再触发，但仍需补上新模型）。
    func ensureBuiltInChatGPTModels(database: AppDatabase) async throws {
        for var provider in try await database.providers()
        where provider.credentialMode == .chatGPTAccount {
            let existing = Set(provider.models.map(\.modelID))
            var changed = false
            for modelID in ChatGPTProviderDefaults.defaultModelIDs
            where !existing.contains(modelID) {
                provider.models.append(ProviderModelRoute(
                    providerID: provider.id,
                    modelID: modelID,
                    displayName: modelID,
                    inputModalities: ["text", "image"],
                    sortOrder: provider.models.count
                ))
                changed = true
            }
            if provider.bridgeModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                provider.bridgeModel = ChatGPTProviderDefaults.defaultModelIDs.first ?? "gpt-5.5"
                changed = true
            }
            if changed {
                provider.updatedAt = Date()
                try await database.saveProvider(provider)
            }
        }
    }

    private func readAuthAPIKey(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = object["OPENAI_API_KEY"] as? String,
              !key.isEmpty else { return nil }
        return key
    }

    private func isChatGPTAccountProvider(_ baseURL: String) -> Bool {
        baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .caseInsensitiveCompare(ChatGPTProviderDefaults.baseURL) == .orderedSame
    }
}

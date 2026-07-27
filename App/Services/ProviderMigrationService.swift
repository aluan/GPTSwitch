import Foundation

struct ProviderMigrationService: Sendable {
    private let configEditor: CodexConfigEditor
    private let credentialStore: any CredentialStore

    init(
        configEditor: CodexConfigEditor = CodexConfigEditor(),
        credentialStore: any CredentialStore = KeychainCredentialStore()
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
        let inspections = try configEditor.inspectProviders(at: configURL, originalConfiguration: configuration)
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

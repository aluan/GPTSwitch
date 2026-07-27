import Foundation

enum ProviderCredentialMode: String, Codable, CaseIterable, Sendable {
    case keychainBearer = "keychain_bearer"
    case keychainAPIKey = "keychain_api_key"
    case passthrough
    case chatGPTAccount = "chatgpt_account"

    var title: String {
        switch self {
        case .keychainBearer: "钥匙串 Bearer Token"
        case .keychainAPIKey: "钥匙串 x-api-key"
        case .passthrough: "沿用 Codex 凭据"
        case .chatGPTAccount: "ChatGPT 账号登录"
        }
    }
}

enum ProviderWireProtocol: String, Codable, CaseIterable, Sendable {
    case responses
    case chatCompletions = "chat_completions"
    case anthropicMessages = "anthropic_messages"

    var title: String {
        switch self {
        case .responses: "Responses API"
        case .chatCompletions: "Chat Completions"
        case .anthropicMessages: "Anthropic Messages"
        }
    }
}

enum ChatCompletionsDialect: String, Codable, CaseIterable, Sendable {
    case standard
    case deepSeek = "deepseek"
    case glm

    var title: String {
        switch self {
        case .standard: "OpenAI Compatible"
        case .deepSeek: "DeepSeek"
        case .glm: "GLM"
        }
    }
}

enum ProviderHealthState: String, Codable, CaseIterable, Sendable {
    case unknown
    case healthy
    case degraded
    case unavailable

    var title: String {
        switch self {
        case .unknown: "未检测"
        case .healthy: "健康"
        case .degraded: "响应较慢"
        case .unavailable: "不可用"
        }
    }

    var symbolName: String {
        switch self {
        case .unknown: "questionmark.circle"
        case .healthy: "checkmark.circle.fill"
        case .degraded: "exclamationmark.circle.fill"
        case .unavailable: "xmark.circle.fill"
        }
    }
}

struct ProviderModelRoute: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var providerID: UUID
    var modelID: String
    var displayName: String
    var modelDescription: String
    var reasoningEfforts: [String]
    var defaultReasoningEffort: String
    var inputModalities: [String]
    var isEnabled: Bool
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        providerID: UUID,
        modelID: String,
        displayName: String = "",
        modelDescription: String = "",
        reasoningEfforts: [String] = ["low", "medium", "high"],
        defaultReasoningEffort: String = "medium",
        inputModalities: [String] = ["text"],
        isEnabled: Bool = true,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.providerID = providerID
        self.modelID = modelID
        self.displayName = displayName
        self.modelDescription = modelDescription
        self.reasoningEfforts = reasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.inputModalities = inputModalities
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
    }

    var encodedModelID: String {
        modelID.replacingOccurrences(of: "/", with: "-")
    }

    func catalogID(providerConfigName: String) -> String {
        "\(providerConfigName)/\(encodedModelID)"
    }

    func validated(for providerID: UUID) throws -> ProviderModelRoute {
        var output = self
        output.providerID = providerID
        output.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        output.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        output.modelDescription = modelDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        output.reasoningEfforts = reasoningEfforts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .uniqued()
        output.defaultReasoningEffort = defaultReasoningEffort
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        output.inputModalities = inputModalities
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .uniqued()
        guard !output.modelID.isEmpty else { throw ProviderValidationError.missingModelRouteID }
        if output.displayName.isEmpty { output.displayName = output.modelID }
        if output.reasoningEfforts.isEmpty { output.defaultReasoningEffort = "" }
        else if !output.reasoningEfforts.contains(output.defaultReasoningEffort) {
            output.defaultReasoningEffort = output.reasoningEfforts[0]
        }
        if output.inputModalities.isEmpty { output.inputModalities = ["text"] }
        return output
    }
}

struct ProviderProfile: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var configName: String
    var displayName: String
    var baseURL: String
    var bridgeModel: String
    var wireProtocol: ProviderWireProtocol
    var chatDialect: ChatCompletionsDialect
    var inferenceModel: String
    var models: [ProviderModelRoute]
    var testModel: String
    var note: String
    var website: String
    var sortOrder: Int
    var credentialMode: ProviderCredentialMode
    var costMultiplier: Double
    var healthState: ProviderHealthState
    var lastHealthLatencyMilliseconds: Int?
    var lastHealthError: String?
    var lastCheckedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        configName: String,
        displayName: String,
        baseURL: String,
        bridgeModel: String,
        wireProtocol: ProviderWireProtocol = .responses,
        chatDialect: ChatCompletionsDialect = .standard,
        inferenceModel: String = "",
        models: [ProviderModelRoute] = [],
        testModel: String = "",
        note: String = "",
        website: String = "",
        sortOrder: Int = 0,
        credentialMode: ProviderCredentialMode = .keychainBearer,
        costMultiplier: Double = 1,
        healthState: ProviderHealthState = .unknown,
        lastHealthLatencyMilliseconds: Int? = nil,
        lastHealthError: String? = nil,
        lastCheckedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.configName = configName
        self.displayName = displayName
        self.baseURL = baseURL
        self.bridgeModel = bridgeModel
        self.wireProtocol = wireProtocol
        self.chatDialect = chatDialect
        self.inferenceModel = inferenceModel
        self.models = models
        self.testModel = testModel
        self.note = note
        self.website = website
        self.sortOrder = sortOrder
        self.credentialMode = credentialMode
        self.costMultiplier = costMultiplier
        self.healthState = healthState
        self.lastHealthLatencyMilliseconds = lastHealthLatencyMilliseconds
        self.lastHealthError = lastHealthError
        self.lastCheckedAt = lastCheckedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var effectiveTestModel: String {
        for candidate in [testModel, inferenceModel, bridgeModel] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    var supportsImageBridge: Bool { wireProtocol == .responses }

    var effectiveModelRoutes: [ProviderModelRoute] {
        if !models.isEmpty { return models.sorted { $0.sortOrder < $1.sortOrder } }
        let fallback = inferenceModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? bridgeModel
            : inferenceModel
        guard !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [ProviderModelRoute(
            providerID: id,
            modelID: fallback,
            displayName: fallback,
            inputModalities: wireProtocol == .responses ? ["text", "image"] : ["text"]
        )]
    }

    func validated(proxyPort: UInt16) throws -> ProviderProfile {
        var output = self
        output.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        output.configName = configName.trimmingCharacters(in: .whitespacesAndNewlines)
        output.bridgeModel = bridgeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        output.inferenceModel = inferenceModel.trimmingCharacters(in: .whitespacesAndNewlines)
        output.models = try models.enumerated().map { index, route in
            var validated = try route.validated(for: id)
            validated.sortOrder = index
            return validated
        }
        output.testModel = testModel.trimmingCharacters(in: .whitespacesAndNewlines)
        output.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        output.website = website.trimmingCharacters(in: .whitespacesAndNewlines)
        output.baseURL = try ProviderURLValidator.normalize(baseURL, proxyPort: proxyPort)
        output.costMultiplier = max(0, costMultiplier)
        output.updatedAt = Date()
        guard !output.displayName.isEmpty else { throw ProviderValidationError.missingName }
        guard !output.configName.isEmpty else { throw ProviderValidationError.missingConfigName }
        guard output.configName.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw ProviderValidationError.invalidConfigName
        }
        let catalogIDs = output.models.map { $0.catalogID(providerConfigName: output.configName) }
        guard Set(catalogIDs).count == catalogIDs.count else {
            throw ProviderValidationError.duplicateModelRoute
        }
        if output.wireProtocol == .responses {
            guard !output.bridgeModel.isEmpty else { throw ProviderValidationError.missingBridgeModel }
        } else {
            guard !output.inferenceModel.isEmpty else { throw ProviderValidationError.missingInferenceModel }
        }
        if output.credentialMode == .chatGPTAccount {
            guard output.wireProtocol == .responses,
                  output.baseURL == ChatGPTProviderDefaults.baseURL else {
                throw ProviderValidationError.invalidChatGPTProvider
            }
        }
        return output
    }
}

struct ActiveProviderSnapshot: Equatable, Sendable {
    let profile: ProviderProfile
    let bearerToken: String?
    let chatGPTAccountID: String?
    var upstreamModelOverride: String? = nil

    init(
        profile: ProviderProfile,
        bearerToken: String?,
        chatGPTAccountID: String? = nil
    ) {
        self.profile = profile
        self.bearerToken = bearerToken
        self.chatGPTAccountID = chatGPTAccountID
    }

    var id: UUID { profile.id }
    var upstreamBaseURL: String { profile.baseURL }
    var bridgeModel: String { upstreamModelOverride ?? profile.bridgeModel }
    var inferenceModel: String { upstreamModelOverride ?? profile.inferenceModel }
}

enum ProviderValidationError: LocalizedError, Equatable {
    case missingName
    case missingConfigName
    case invalidConfigName
    case duplicateConfigName
    case missingBridgeModel
    case missingInferenceModel
    case missingModelRouteID
    case duplicateModelRoute
    case invalidURL(String)
    case proxyLoop
    case missingCredential
    case incompatibleToolCalling(String)
    case activeProviderCannotBeDeleted
    case missingProvider
    case invalidChatGPTProvider

    var errorDescription: String? {
        switch self {
        case .missingName: "Provider 名称不能为空"
        case .missingConfigName: "Provider 配置标识不能为空"
        case .invalidConfigName: "Provider 配置标识只能包含字母、数字、下划线和连字符"
        case .duplicateConfigName: "该配置标识已被其他 Provider 占用，请改为唯一标识"
        case .missingBridgeModel: "桥接模型不能为空"
        case .missingInferenceModel: "Chat Provider 的推理模型不能为空"
        case .missingModelRouteID: "模型 ID 不能为空"
        case .duplicateModelRoute: "Provider 中存在冲突的模型目录 ID"
        case .invalidURL(let value): "无效的 Provider 地址：\(value)"
        case .proxyLoop: "Provider 地址不能指向 GPTSwitch 自身监听端口"
        case .missingCredential: "该 Provider 尚未保存 API Key"
        case .incompatibleToolCalling(let message): "无法启用 Provider：\(message)"
        case .activeProviderCannotBeDeleted: "请先切换到其他 Provider，再删除当前 Provider"
        case .missingProvider: "找不到指定的 Provider"
        case .invalidChatGPTProvider: "ChatGPT 账号 Provider 必须使用官方 ChatGPT Responses 地址"
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

enum ProviderURLValidator {
    static func normalize(_ value: String, proxyPort: UInt16) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.fragment == nil else {
            throw ProviderValidationError.invalidURL(value)
        }
        if ["127.0.0.1", "localhost", "::1"].contains(host.lowercased()),
           components.port == Int(proxyPort) {
            throw ProviderValidationError.proxyLoop
        }
        components.scheme = scheme
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            ? ""
            : "/\(components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        components.query = nil
        guard let normalized = components.url?.absoluteString else {
            throw ProviderValidationError.invalidURL(value)
        }
        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

protocol ProviderRepository: Sendable {
    func providers() async throws -> [ProviderProfile]
    func saveProvider(_ provider: ProviderProfile) async throws
    func deleteProvider(id: UUID) async throws
    func activeProviderID() async throws -> UUID?
    func setActiveProvider(id: UUID) async throws
    func reorderProviders(ids: [UUID]) async throws
}

protocol CredentialStore: Sendable {
    func token(for providerID: UUID) throws -> String?
    func setToken(_ token: String, for providerID: UUID) throws
    func deleteToken(for providerID: UUID) throws
}

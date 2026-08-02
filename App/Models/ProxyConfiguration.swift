import Foundation

struct ProxyConfiguration: Codable, Equatable, Sendable {
    static let currentToolVersion = "1.4.1"

    var toolVersion: String
    var configPath: String
    var providerName: String
    var bridgeModel: String
    var upstreamBaseURL: String
    var localBaseURL: String
    var port: UInt16
    var backupPath: String?
    var installedAt: Date
    var isEnabled: Bool
    /// 标记当前 provider 段是否由 GPTSwitch 注入（裸 ChatGPT 账号流场景）。
    /// true：restore 时移除整个注入段 + model_provider 行，还原成裸流；
    /// false：restore 时仅改写 base_url 到上游（保留用户已有的段）。
    var providerSectionInjected: Bool

    init(
        toolVersion: String = Self.currentToolVersion,
        configPath: String,
        providerName: String,
        bridgeModel: String,
        upstreamBaseURL: String,
        localBaseURL: String,
        port: UInt16,
        backupPath: String?,
        installedAt: Date = Date(),
        isEnabled: Bool = true,
        providerSectionInjected: Bool = false
    ) {
        self.toolVersion = toolVersion
        self.configPath = configPath
        self.providerName = providerName
        self.bridgeModel = bridgeModel
        self.upstreamBaseURL = upstreamBaseURL
        self.localBaseURL = localBaseURL
        self.port = port
        self.backupPath = backupPath
        self.installedAt = installedAt
        self.isEnabled = isEnabled
        self.providerSectionInjected = providerSectionInjected
    }

    enum CodingKeys: String, CodingKey {
        case toolVersion = "tool_version"
        case configPath = "config_path"
        case providerName = "provider_name"
        case bridgeModel = "bridge_model"
        case upstreamBaseURL = "upstream_base_url"
        case localBaseURL = "local_base_url"
        case port
        case backupPath = "backup_path"
        case installedAt = "installed_at"
        case isEnabled = "is_enabled"
        case providerSectionInjected = "provider_section_injected"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolVersion = try container.decodeIfPresent(String.self, forKey: .toolVersion) ?? Self.currentToolVersion
        configPath = try container.decode(String.self, forKey: .configPath)
        providerName = try container.decode(String.self, forKey: .providerName)
        bridgeModel = try container.decode(String.self, forKey: .bridgeModel)
        upstreamBaseURL = try container.decode(String.self, forKey: .upstreamBaseURL)
        localBaseURL = try container.decode(String.self, forKey: .localBaseURL)
        port = try container.decode(UInt16.self, forKey: .port)
        backupPath = try container.decodeIfPresent(String.self, forKey: .backupPath)
        if let timestamp = try? container.decode(TimeInterval.self, forKey: .installedAt) {
            installedAt = Date(timeIntervalSince1970: timestamp)
        } else {
            installedAt = try container.decodeIfPresent(Date.self, forKey: .installedAt) ?? Date()
        }
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        providerSectionInjected = try container.decodeIfPresent(Bool.self, forKey: .providerSectionInjected) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolVersion, forKey: .toolVersion)
        try container.encode(configPath, forKey: .configPath)
        try container.encode(providerName, forKey: .providerName)
        try container.encode(bridgeModel, forKey: .bridgeModel)
        try container.encode(upstreamBaseURL, forKey: .upstreamBaseURL)
        try container.encode(localBaseURL, forKey: .localBaseURL)
        try container.encode(port, forKey: .port)
        try container.encodeIfPresent(backupPath, forKey: .backupPath)
        try container.encode(installedAt.timeIntervalSince1970, forKey: .installedAt)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(providerSectionInjected, forKey: .providerSectionInjected)
    }
}

enum ProxyRuntimeStatus: Equatable, Sendable {
    case notConfigured
    case stopped
    case starting
    case running
    case testing
    case failed(String)

    var title: String {
        switch self {
        case .notConfigured: "未配置"
        case .stopped: "已停止"
        case .starting: "正在启动"
        case .running: "运行正常"
        case .testing: "正在自检"
        case .failed: "运行异常"
        }
    }

    var symbolName: String {
        switch self {
        case .running: "checkmark.circle.fill"
        case .starting, .testing: "arrow.triangle.2.circlepath.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .notConfigured, .stopped: "circle"
        }
    }
}

struct ProxyMetrics: Equatable, Sendable {
    var forwardedRequests = 0
    var bridgedImages = 0
    var failedRequests = 0
    var lastActivity: Date?
}

enum ProxyEvent: Sendable {
    case forwarded
    case imageBridged
    case failed(String)
}

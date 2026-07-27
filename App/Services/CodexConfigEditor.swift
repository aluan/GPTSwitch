import Foundation

struct ConfigInspection: Equatable, Sendable {
    let configPath: String
    let providerName: String
    let model: String
    let baseURL: String
}

struct ProviderConfigInspection: Equatable, Sendable {
    let configName: String
    let displayName: String
    let baseURL: String
    let bearerToken: String?
    let environmentKey: String?
    let isCurrent: Bool
    let model: String
}

enum ConfigEditorError: LocalizedError {
    case missingConfig(String)
    case missingTopLevelKey(String)
    case missingProvider(String)
    case missingProviderKey(String)
    case invalidString(String)
    case invalidUpstreamURL(String)
    case alreadyUsingLoopback
    case configurationChanged(String)
    case missingAuthentication

    var errorDescription: String? {
        switch self {
        case .missingConfig(let path): "无法读取 Codex 配置：\(path)"
        case .missingTopLevelKey(let key): "Codex 配置缺少顶层 `\(key)`"
        case .missingProvider(let provider): "未找到 `[model_providers.\(provider)]`"
        case .missingProviderKey(let key): "当前 Provider 缺少 `\(key)`"
        case .invalidString(let key): "无法解析 `\(key)` 的 TOML 字符串"
        case .invalidUpstreamURL(let value): "无效的上游地址：\(value)"
        case .alreadyUsingLoopback: "当前 Provider 已指向本机，但没有可迁移的旧状态"
        case .configurationChanged(let current): "当前 base_url 已被修改，未自动覆盖：\(current)"
        case .missingAuthentication: "自检仅支持 experimental_bearer_token 或 env_key 认证"
        }
    }
}

struct CodexConfigEditor: Sendable {
    private struct ParsedConfig {
        let lines: [String]
        let providerName: String
        let model: String
        let baseURL: String
        let baseURLLineIndex: Int
        let baseURLPrefix: String
    }

    func inspect(at url: URL = AppPaths.codexConfig) throws -> ConfigInspection {
        let parsed = try parse(url)
        return ConfigInspection(
            configPath: url.path,
            providerName: parsed.providerName,
            model: parsed.model,
            baseURL: parsed.baseURL
        )
    }

    func inspectProviders(
        at url: URL = AppPaths.codexConfig,
        originalConfiguration: ProxyConfiguration? = nil
    ) throws -> [ProviderConfigInspection] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigEditorError.missingConfig(url.path)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let currentProvider = try topLevelString(lines: lines, key: "model_provider")
        let model = try topLevelString(lines: lines, key: "model")
        var output: [ProviderConfigInspection] = []
        for sectionStart in lines.indices {
            guard let configName = providerSectionName(lines[sectionStart]) else { continue }
            var values: [String: String] = [:]
            for index in lines.indices where index > sectionStart {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") { break }
                for key in ["name", "base_url", "experimental_bearer_token", "env_key"] {
                    if let assignment = assignment(line, key: key),
                       let value = try? parseTOMLString(assignment.value, key: key) {
                        values[key] = value
                    }
                }
            }
            guard var baseURL = values["base_url"], !baseURL.isEmpty else { continue }
            let isCurrent = configName == currentProvider
            if isCurrent, let originalConfiguration {
                baseURL = originalConfiguration.upstreamBaseURL
            }
            output.append(ProviderConfigInspection(
                configName: configName,
                displayName: values["name"]?.nilIfEmpty ?? configName,
                baseURL: baseURL,
                bearerToken: values["experimental_bearer_token"]?.nilIfEmpty,
                environmentKey: values["env_key"]?.nilIfEmpty,
                isCurrent: isCurrent,
                model: isCurrent ? (originalConfiguration?.bridgeModel ?? model) : model
            ))
        }
        return output
    }

    func enable(
        at configURL: URL = AppPaths.codexConfig,
        port: UInt16,
        bridgeModel override: String?
    ) throws -> ProxyConfiguration {
        let parsed = try parse(configURL)
        let upstream = try validatedUpstream(parsed.baseURL)
        let localURL = localBaseURL(for: upstream, port: port)
        let backupURL = try createBackup(of: configURL)
        try replaceBaseURL(
            in: configURL,
            parsed: parsed,
            replacement: localURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
        return ProxyConfiguration(
            configPath: configURL.path,
            providerName: parsed.providerName,
            bridgeModel: normalizedModel(override) ?? parsed.model,
            upstreamBaseURL: upstream.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            localBaseURL: localURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            port: port,
            backupPath: backupURL.path
        )
    }

    func adoptLoopback(
        at configURL: URL = AppPaths.codexConfig,
        port: UInt16,
        bridgeModel override: String?,
        upstreamBaseURL: String
    ) throws -> ProxyConfiguration {
        let parsed = try parse(configURL)
        let upstream = try validatedUpstream(upstreamBaseURL)
        let localURL = localBaseURL(for: upstream, port: port)
        guard normalizedBaseURL(parsed.baseURL) == normalizedBaseURL(localURL.absoluteString) else {
            throw ConfigEditorError.configurationChanged(parsed.baseURL)
        }
        return ProxyConfiguration(
            configPath: configURL.path,
            providerName: parsed.providerName,
            bridgeModel: normalizedModel(override) ?? parsed.model,
            upstreamBaseURL: upstream.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            localBaseURL: localURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            port: port,
            backupPath: nil
        )
    }

    func activate(_ configuration: ProxyConfiguration) throws {
        let configURL = URL(fileURLWithPath: configuration.configPath)
        let parsed = try parse(configURL)
        let current = normalizedBaseURL(parsed.baseURL)
        let local = normalizedBaseURL(configuration.localBaseURL)
        guard current != local else { return }
        guard current == normalizedBaseURL(configuration.upstreamBaseURL) else {
            throw ConfigEditorError.configurationChanged(parsed.baseURL)
        }
        try replaceBaseURL(
            in: configURL,
            parsed: parsed,
            replacement: configuration.localBaseURL
        )
    }

    func restore(_ configuration: ProxyConfiguration) throws {
        let configURL = URL(fileURLWithPath: configuration.configPath)
        let parsed = try parse(configURL)
        let current = normalizedBaseURL(parsed.baseURL)
        let upstream = normalizedBaseURL(configuration.upstreamBaseURL)
        guard current != upstream else { return }
        guard current == normalizedBaseURL(configuration.localBaseURL) else {
            throw ConfigEditorError.configurationChanged(parsed.baseURL)
        }
        try replaceBaseURL(
            in: configURL,
            parsed: parsed,
            replacement: configuration.upstreamBaseURL
        )
    }

    func bearerToken(for configuration: ProxyConfiguration) throws -> String {
        let configURL = URL(fileURLWithPath: configuration.configPath)
        let text = try String(contentsOf: configURL, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        if let token = try providerString(
            lines: lines,
            providerName: configuration.providerName,
            key: "experimental_bearer_token"
        ), !token.isEmpty {
            return token
        }
        if let environmentKey = try providerString(
            lines: lines,
            providerName: configuration.providerName,
            key: "env_key"
        ), let token = ProcessInfo.processInfo.environment[environmentKey], !token.isEmpty {
            return token
        }
        throw ConfigEditorError.missingAuthentication
    }

    private func parse(_ url: URL) throws -> ParsedConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigEditorError.missingConfig(url.path)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let providerName = try topLevelString(lines: lines, key: "model_provider")
        let model = try topLevelString(lines: lines, key: "model")
        guard let sectionStart = lines.firstIndex(where: { providerSectionName($0) == providerName }) else {
            throw ConfigEditorError.missingProvider(providerName)
        }
        for index in lines.indices where index > sectionStart {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                break
            }
            if let assignment = assignment(line, key: "base_url") {
                return ParsedConfig(
                    lines: lines,
                    providerName: providerName,
                    model: model,
                    baseURL: try parseTOMLString(assignment.value, key: "base_url"),
                    baseURLLineIndex: index,
                    baseURLPrefix: assignment.prefix
                )
            }
        }
        throw ConfigEditorError.missingProviderKey("base_url")
    }

    private func topLevelString(lines: [String], key: String) throws -> String {
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                break
            }
            if let assignment = assignment(line, key: key) {
                return try parseTOMLString(assignment.value, key: key)
            }
        }
        throw ConfigEditorError.missingTopLevelKey(key)
    }

    private func providerString(lines: [String], providerName: String, key: String) throws -> String? {
        guard let sectionStart = lines.firstIndex(where: { providerSectionName($0) == providerName }) else {
            throw ConfigEditorError.missingProvider(providerName)
        }
        for index in lines.indices where index > sectionStart {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                break
            }
            if let assignment = assignment(line, key: key) {
                return try parseTOMLString(assignment.value, key: key)
            }
        }
        return nil
    }

    private func assignment(_ line: String, key: String) -> (prefix: String, value: String)? {
        let pattern = "^(\\s*\(NSRegularExpression.escapedPattern(for: key))\\s*=\\s*)(.+?)\\s*$"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let prefixRange = Range(match.range(at: 1), in: line),
              let valueRange = Range(match.range(at: 2), in: line) else {
            return nil
        }
        return (String(line[prefixRange]), String(line[valueRange]))
    }

    private func providerSectionName(_ line: String) -> String? {
        let pattern = #"^\s*\[model_providers\.(?:\"([^\"]+)\"|([A-Za-z0-9_-]+))\]\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }
        for capture in [1, 2] {
            if match.range(at: capture).location != NSNotFound,
               let range = Range(match.range(at: capture), in: line) {
                return String(line[range])
            }
        }
        return nil
    }

    private func parseTOMLString(_ value: String, key: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\"") {
            let data = Data("[\(trimmed)]".utf8)
            guard let array = try? JSONSerialization.jsonObject(with: data) as? [String],
                  let result = array.first else {
                throw ConfigEditorError.invalidString(key)
            }
            return result
        }
        if trimmed.hasPrefix("'"), trimmed.hasSuffix("'"), trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        throw ConfigEditorError.invalidString(key)
    }

    private func validatedUpstream(_ value: String) throws -> URL {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else {
            throw ConfigEditorError.invalidUpstreamURL(value)
        }
        if ["127.0.0.1", "localhost", "::1"].contains(host.lowercased()) {
            throw ConfigEditorError.alreadyUsingLoopback
        }
        return url
    }

    private func localBaseURL(for upstream: URL, port: UInt16) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = upstream.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            ? ""
            : "/\(upstream.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        return components.url!
    }

    private func createBackup(of configURL: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        let backup = configURL.deletingLastPathComponent().appendingPathComponent(
            "\(configURL.lastPathComponent).codex-imagegen-app.\(formatter.string(from: Date())).bak"
        )
        try FileManager.default.copyItem(at: configURL, to: backup)
        return backup
    }

    private func replaceBaseURL(in url: URL, parsed: ParsedConfig, replacement: String) throws {
        var lines = parsed.lines
        let encoded = try JSONSerialization.data(withJSONObject: [replacement], options: [.withoutEscapingSlashes])
        let array = String(decoding: encoded, as: UTF8.self)
        let quoted = String(array.dropFirst().dropLast())
        lines[parsed.baseURLLineIndex] = "\(parsed.baseURLPrefix)\(quoted)"
        let data = Data(lines.joined(separator: "\n").utf8)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try data.write(to: url, options: .atomic)
        if let permissions = attributes[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }

    private func normalizedModel(_ model: String?) -> String? {
        model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func normalizedBaseURL(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

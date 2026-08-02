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
        /// 裸 ChatGPT 账号流：config 无 model_provider 也无 [model_providers.*] 段。
        /// true 表示需注入段而非改写既有 base_url 行（baseURLLineIndex 为 -1 哨兵）。
        let sectionMissing: Bool
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
        // 裸 ChatGPT 账号流：注入 [model_providers.chatgpt] 段 + model_provider。
        if parsed.sectionMissing {
            let upstream = try validatedUpstream(parsed.baseURL)
            let localURL = localBaseURL(for: upstream, port: port)
            let backupURL = try createBackup(of: configURL)
            try injectChatGPTProviderSection(
                in: configURL,
                providerName: parsed.providerName,
                baseURLValue: localURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            )
            return ProxyConfiguration(
                configPath: configURL.path,
                providerName: parsed.providerName,
                bridgeModel: normalizedModel(override) ?? parsed.model,
                upstreamBaseURL: upstream.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                localBaseURL: localURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                port: port,
                backupPath: backupURL.path,
                providerSectionInjected: true
            )
        }
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
        // 裸流重激活：用户停用后段被移除，重新注入 loopback 段。
        if parsed.sectionMissing {
            guard configuration.providerSectionInjected,
                  configuration.providerName == parsed.providerName else {
                throw ConfigEditorError.configurationChanged(parsed.baseURL)
            }
            try injectChatGPTProviderSection(
                in: configURL,
                providerName: parsed.providerName,
                baseURLValue: configuration.localBaseURL
            )
            return
        }
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
        // 注入型段：移除整个 [model_providers.<name>] 段 + model_provider 行，还原裸流。
        if configuration.providerSectionInjected {
            // 已还原成裸流（段已移除，parse 合成 baseURL==upstream）→ 幂等 no-op。
            if parsed.sectionMissing, current == upstream { return }
            let local = normalizedBaseURL(configuration.localBaseURL)
            guard current == local else {
                throw ConfigEditorError.configurationChanged(parsed.baseURL)
            }
            let text = try String(contentsOf: configURL, encoding: .utf8)
            var lines = text.components(separatedBy: "\n")
            lines = removeInjectedChatGPTSection(lines: lines, providerName: configuration.providerName)
            try writeLines(lines, to: configURL)
            return
        }
        // 非注入（含旧存档回退）：仅改写 base_url 到上游，保留段。
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
        // 裸 ChatGPT 账号流：顶层无 model_provider 且全文零 [model_providers.*] 段。
        // 合成 chatgpt provider，后续 enable/activate 走注入路径。
        let topLevelRegion = topLevelLineCount(in: lines)
        let hasTopLevelModelProvider = lines.prefix(topLevelRegion)
            .contains { assignment($0, key: "model_provider") != nil }
        let sectionCount = lines.filter { providerSectionName($0) != nil }.count
        if !hasTopLevelModelProvider, sectionCount == 0 {
            let model = (try? topLevelString(lines: lines, key: "model"))
                ?? ChatGPTProviderDefaults.defaultModelIDs.first
                ?? "gpt-5"
            return ParsedConfig(
                lines: lines,
                providerName: ChatGPTProviderDefaults.configName,
                model: model,
                baseURL: ChatGPTProviderDefaults.baseURL,
                baseURLLineIndex: -1,
                baseURLPrefix: "base_url = ",
                sectionMissing: true
            )
        }
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
                    baseURLPrefix: assignment.prefix,
                    sectionMissing: false
                )
            }
        }
        throw ConfigEditorError.missingProviderKey("base_url")
    }

    /// 顶层区行数：从开头到首个表头行（`[` 开头）之前。
    private func topLevelLineCount(in lines: [String]) -> Int {
        if let firstSection = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) {
            return firstSection
        }
        return lines.count
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
        try writeLines(lines, to: url)
    }

    /// 原子写入行数组并保留 POSIX 权限。
    private func writeLines(_ lines: [String], to url: URL) throws {
        let data = Data(lines.joined(separator: "\n").utf8)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try data.write(to: url, options: .atomic)
        if let permissions = attributes[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }

    /// 把 TOML 字符串值用双引号包裹（与 replaceBaseURL 的编码一致，不转义斜杠）。
    private func quotedTOMLString(_ value: String) throws -> String {
        let encoded = try JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        let array = String(decoding: encoded, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    /// 注入 [model_providers.<providerName>] 段（base_url 指向 loopback），
    /// 并确保顶层存在 model_provider = "<providerName>"。幂等：段已存在则不动。
    private func injectChatGPTProviderSection(
        in url: URL,
        providerName: String,
        baseURLValue: String
    ) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        guard lines.firstIndex(where: { providerSectionName($0) == providerName }) == nil else {
            return // 段已存在，不重复注入
        }
        let quotedURL = try quotedTOMLString(baseURLValue)
        let quotedProvider = try quotedTOMLString(providerName)
        // 顶层 model_provider：找到首个 [ 行，在其前插入或原地替换。
        let firstSection = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) ?? lines.count
        var insertedModelProvider = false
        for index in 0..<firstSection {
            if let existing = assignment(lines[index], key: "model_provider") {
                lines[index] = "\(existing.prefix)\(quotedProvider)"
                insertedModelProvider = true
                break
            }
        }
        if !insertedModelProvider {
            lines.insert("model_provider = \(quotedProvider)", at: firstSection)
        }
        // 末尾追加段块（与前文空行分隔）。
        if let last = lines.last, !last.isEmpty { lines.append("") }
        lines.append("[model_providers.\(providerName)]")
        lines.append("name = \"ChatGPT\"")
        lines.append("base_url = \(quotedURL)")
        try writeLines(lines, to: url)
    }

    /// 移除注入的 [model_providers.<providerName>] 段及其顶层 model_provider 行。
    private func removeInjectedChatGPTSection(lines: [String], providerName: String) -> [String] {
        var output: [String] = []
        var skipping = false
        for line in lines {
            if skipping {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                    skipping = false
                } else {
                    continue
                }
            }
            if providerSectionName(line) == providerName {
                skipping = true
                continue
            }
            // 仅当 model_provider 值等于注入名时移除该顶层行。
            if let existing = assignment(line, key: "model_provider"),
               let parsed = try? parseTOMLString(existing.value, key: "model_provider"),
               parsed == providerName,
               !line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                continue
            }
            output.append(line)
        }
        // 移除因段删除残留的尾部空行。
        while output.last?.isEmpty == true { output.removeLast() }
        return output
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

import Foundation

struct CodexCatalogSyncResult: Equatable, Sendable {
    let catalogPath: String
    let routedModelCount: Int
}

enum CodexModelCatalogError: LocalizedError {
    case invalidConfig
    case invalidCatalog
    case configurationChanged(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfig: "无法更新 Codex 模型目录配置"
        case .invalidCatalog: "无法生成 Codex 模型目录"
        case .configurationChanged(let path): "Codex 模型目录已被其他程序修改：\(path)"
        }
    }
}

struct CodexModelCatalogService: Sendable {
    private struct State: Codable {
        let originalCatalogPath: String?
        let originalModel: String?
    }

    func sync(
        provider: ProviderProfile,
        allProviders: [ProviderProfile] = [],
        crossProvider: Bool = false,
        configURL: URL = AppPaths.codexConfig,
        catalogURL: URL = AppPaths.codexModelCatalog,
        cacheURL: URL = AppPaths.codexModelsCache,
        stateURL: URL = AppPaths.codexCatalogState,
        nativeBackupURL: URL = AppPaths.codexNativeCatalogBackup
    ) throws -> CodexCatalogSyncResult {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: catalogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let config = try String(contentsOf: configURL, encoding: .utf8)
        let currentCatalogPath = rootString(in: config, key: "model_catalog_json")
        let currentModel = rootString(in: config, key: "model")
        let storedState = try readState(stateURL)
        let state: State
        if let storedState {
            if storedState.originalModel != nil {
                state = storedState
            } else {
                state = State(
                    originalCatalogPath: storedState.originalCatalogPath,
                    originalModel: currentModel
                )
                try writeJSON(state, to: stateURL)
            }
        } else {
            state = State(
                originalCatalogPath: currentCatalogPath == catalogURL.path ? nil : currentCatalogPath,
                originalModel: currentModel
            )
            try writeJSON(state, to: stateURL)
        }

        let nativeCatalog = try nativeCatalogObject(
            originalCatalogPath: state.originalCatalogPath,
            configDirectory: configURL.deletingLastPathComponent(),
            cacheURL: cacheURL,
            backupURL: nativeBackupURL
        )
        let nativeModels = nativeCatalog["models"] as? [[String: Any]] ?? []
        guard let template = nativeModels.first(where: {
            ($0["slug"] as? String)?.contains("/") == false && $0["base_instructions"] != nil
        }) ?? nativeModels.first else {
            throw CodexModelCatalogError.invalidCatalog
        }

        var routedModels: [[String: Any]] = []
        var priority = 100
        // 跨 provider 路由开启时，一次性列出所有 provider 的模型，使 catalog 不随激活 provider
        // 切换而变化——Codex CLI 不必重启即可见全部模型。否则只列激活 provider 的模型。
        let providersToList: [ProviderProfile]
        if crossProvider, !allProviders.isEmpty {
            providersToList = allProviders.filter { $0.healthState != .unavailable }
        } else {
            providersToList = provider.healthState != .unavailable ? [provider] : []
        }
        for profile in providersToList {
            for route in profile.effectiveModelRoutes where route.isEnabled {
                routedModels.append(makeCatalogEntry(
                    template: template,
                    provider: profile,
                    route: route,
                    priority: priority
                ))
                priority += 1
            }
        }
        var outputCatalog = nativeCatalog
        outputCatalog["models"] = routedModels
        try writeJSONObject(outputCatalog, to: catalogURL)

        let updatedConfig = replacingRootString(
            in: config,
            key: "model_catalog_json",
            value: catalogURL.path
        )
        let routedModelIDs = routedModels.compactMap { $0["slug"] as? String }
        let selectedModel = currentModel.flatMap { routedModelIDs.contains($0) ? $0 : nil }
            ?? routedModelIDs.first
        let activatedConfig = replacingRootString(
            in: updatedConfig,
            key: "model",
            value: selectedModel ?? currentModel
        )
        try atomicWrite(Data(activatedConfig.utf8), to: configURL)
        try writeModelsCache(models: outputCatalog["models"] as? [[String: Any]] ?? [], to: cacheURL)
        return CodexCatalogSyncResult(catalogPath: catalogURL.path, routedModelCount: routedModels.count)
    }

    func restore(
        configURL: URL = AppPaths.codexConfig,
        catalogURL: URL = AppPaths.codexModelCatalog,
        cacheURL: URL = AppPaths.codexModelsCache,
        stateURL: URL = AppPaths.codexCatalogState,
        nativeBackupURL: URL = AppPaths.codexNativeCatalogBackup
    ) throws {
        guard FileManager.default.fileExists(atPath: configURL.path),
              let state = try readState(stateURL) else { return }
        let config = try String(contentsOf: configURL, encoding: .utf8)
        let current = rootString(in: config, key: "model_catalog_json")
        guard current == catalogURL.path else {
            throw CodexModelCatalogError.configurationChanged(current ?? "未设置")
        }
        let restored = replacingRootString(
            in: config,
            key: "model_catalog_json",
            value: state.originalCatalogPath
        )
        let restoredModel = state.originalModel.map {
            replacingRootString(in: restored, key: "model", value: $0)
        } ?? restored
        try atomicWrite(Data(restoredModel.utf8), to: configURL)
        if let backup = try? readJSONObject(nativeBackupURL),
           let models = backup["models"] as? [[String: Any]] {
            try writeModelsCache(models: models, to: cacheURL)
        }
        try? FileManager.default.removeItem(at: catalogURL)
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: nativeBackupURL)
    }

    func modelsResponse(
        provider: ProviderProfile,
        catalogURL: URL = AppPaths.codexModelCatalog,
        codexShape: Bool,
        crossProvider: Bool = false
    ) throws -> Data {
        let catalog = try readJSONObject(catalogURL)
        let models = (catalog["models"] as? [[String: Any]] ?? []).filter { entry in
            guard let slug = entry["slug"] as? String,
                  let slash = slug.firstIndex(of: "/") else { return false }
            return crossProvider || String(slug[..<slash]) == provider.configName
        }
        if codexShape {
            return try JSONSerialization.data(withJSONObject: ["models": models])
        }
        let data = models.map { entry -> [String: Any] in
            [
                "id": entry["slug"] as? String ?? "",
                "object": "model",
                "owned_by": (entry["slug"] as? String)?.split(separator: "/").first.map(String.init) ?? "gptswitch",
                "display_name": entry["display_name"] as? String ?? entry["slug"] as? String ?? "",
                "supported_reasoning_levels": entry["supported_reasoning_levels"] as? [[String: Any]] ?? [],
                "input_modalities": entry["input_modalities"] as? [String] ?? ["text"],
            ]
        }
        return try JSONSerialization.data(withJSONObject: ["object": "list", "data": data])
    }

    private func makeCatalogEntry(
        template: [String: Any],
        provider: ProviderProfile,
        route: ProviderModelRoute,
        priority: Int
    ) -> [String: Any] {
        var entry = template
        let catalogID = route.catalogID(providerConfigName: provider.configName)
        entry["slug"] = catalogID
        entry["display_name"] = route.displayName.isEmpty ? catalogID : route.displayName
        entry["description"] = route.modelDescription.isEmpty
            ? "通过 GPTSwitch 路由到 \(provider.displayName)"
            : route.modelDescription
        entry["priority"] = priority
        entry["visibility"] = "list"
        entry["supported_in_api"] = true
        entry["input_modalities"] = route.inputModalities
        // codex 0.144+ 严格要求每个 catalog 模型含 supports_reasoning_summaries；
        // 旧 native 备份不含该字段，缺失会导致 codex 解析 catalog 失败、拒绝运行。
        // 模板若未提供则默认 false（不展示 reasoning summaries，安全降级）。
        if entry["supports_reasoning_summaries"] == nil {
            entry["supports_reasoning_summaries"] = false
        }
        // 强制关闭 Responses-Lite 与 WebSocket：chatgpt 账号后端在 Lite 模式下
        // 不支持 gpt-5.5 等（返回 "This model is not supported when using
        // X-OpenAI-Internal-Codex-Responses-Lite"）。GPTSwitch 走完整 Responses
        // 转发，统一禁用 Lite/WebSocket，避免 codex 0.146+ 误启用。
        entry["use_responses_lite"] = false
        entry["responses_websockets"] = false
        if route.reasoningEfforts.isEmpty {
            entry.removeValue(forKey: "supported_reasoning_levels")
            entry.removeValue(forKey: "default_reasoning_level")
        } else {
            entry["supported_reasoning_levels"] = route.reasoningEfforts.map {
                ["effort": $0, "description": reasoningDescription($0)]
            }
            entry["default_reasoning_level"] = route.defaultReasoningEffort.isEmpty
                ? route.reasoningEfforts[0]
                : route.defaultReasoningEffort
        }
        for key in [
            "additional_speed_tiers", "service_tier", "service_tiers",
            "default_service_tier", "availability_nux", "upgrade",
        ] {
            entry.removeValue(forKey: key)
        }
        return entry
    }

    private func nativeCatalogObject(
        originalCatalogPath: String?,
        configDirectory: URL,
        cacheURL: URL,
        backupURL: URL
    ) throws -> [String: Any] {
        if FileManager.default.fileExists(atPath: backupURL.path) {
            return try readJSONObject(backupURL)
        }
        let sourceURL: URL
        if let originalCatalogPath {
            let expanded = NSString(string: originalCatalogPath).expandingTildeInPath
            sourceURL = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded)
                : configDirectory.appendingPathComponent(expanded)
        } else {
            sourceURL = cacheURL
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return defaultCatalogObject()
        }
        var object = try readJSONObject(sourceURL)
        if object["models"] == nil, let data = object["data"] { object["models"] = data }
        guard object["models"] is [[String: Any]] else { throw CodexModelCatalogError.invalidCatalog }
        try writeJSONObject(object, to: backupURL)
        return object
    }

    private func defaultCatalogObject() -> [String: Any] {
        [
            "fetched_at": "2000-01-01T00:00:00Z",
            "client_version": "0.0.0",
            "models": [[
                "slug": "gptswitch-template",
                "display_name": "GPTSwitch",
                "description": "GPTSwitch Provider model",
                "base_instructions": "Be helpful and follow the user's instructions.",
                "default_reasoning_level": "medium",
                "supported_reasoning_levels": [
                    ["effort": "low", "description": "Fast responses with lighter reasoning"],
                    ["effort": "medium", "description": "Balances speed and reasoning depth"],
                    ["effort": "high", "description": "Greater reasoning depth for complex problems"],
                ],
                "shell_type": "shell_command",
                "supported_in_api": true,
                "visibility": "list",
            ]],
        ]
    }

    private func writeModelsCache(models: [[String: Any]], to url: URL) throws {
        try writeJSONObject([
            "fetched_at": "2000-01-01T00:00:00Z",
            "client_version": "0.0.0",
            "models": models,
        ], to: url)
    }

    private func reasoningDescription(_ effort: String) -> String {
        switch effort {
        case "low": "Fast responses with lighter reasoning"
        case "medium": "Balances speed and reasoning depth"
        case "high": "Greater reasoning depth for complex problems"
        case "xhigh": "Extra high reasoning depth"
        case "max": "Maximum reasoning depth"
        case "ultra": "Maximum reasoning with client delegation"
        default: effort
        }
    }

    private func rootString(in text: String, key: String) -> String? {
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") { break }
            guard let assignment = rootAssignment(line, key: key) else { continue }
            let value = assignment.value.trimmingCharacters(in: .whitespaces)
            guard let data = "[\(value)]".data(using: .utf8),
                  let strings = try? JSONDecoder().decode([String].self, from: data) else { return nil }
            return strings.first
        }
        return nil
    }

    private func replacingRootString(in text: String, key: String, value: String?) -> String {
        var lines = text.components(separatedBy: "\n")
        if let index = lines.indices.first(where: { rootAssignment(lines[$0], key: key) != nil }) {
            if let value { lines[index] = "\(key) = \(quoted(value))" }
            else { lines.remove(at: index) }
            return lines.joined(separator: "\n")
        }
        guard let value else { return text }
        let tableIndex = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
        lines.insert("\(key) = \(quoted(value))", at: tableIndex ?? lines.endIndex)
        return lines.joined(separator: "\n")
    }

    private func rootAssignment(_ line: String, key: String) -> (value: String, prefix: String)? {
        let pattern = "^(\\s*\(NSRegularExpression.escapedPattern(for: key))\\s*=\\s*)(.+?)\\s*$"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let prefixRange = Range(match.range(at: 1), in: line),
              let valueRange = Range(match.range(at: 2), in: line) else { return nil }
        return (String(line[valueRange]), String(line[prefixRange]))
    }

    private func quoted(_ value: String) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: [value],
            options: [.withoutEscapingSlashes]
        )
        guard let data else { return "\"\"" }
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    private func readState(_ url: URL) throws -> State? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
    }

    private func readJSONObject(_ url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw CodexModelCatalogError.invalidCatalog
        }
        return object
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try atomicWrite(data, to: url)
    }

    private func writeJSONObject(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try atomicWrite(data, to: url)
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

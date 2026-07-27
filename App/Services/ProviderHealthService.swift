import Foundation

struct ProviderHealthResult: Equatable, Sendable {
    let state: ProviderHealthState
    let latencyMilliseconds: Int
    let statusCode: Int?
    let message: String?
}

private extension Array where Element: Hashable {
    func uniquedPreservingOrder() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

struct ProviderHealthService: Sendable {
    func discoverModels(provider: ProviderProfile, token: String?) async throws -> [String] {
        if provider.credentialMode == .chatGPTAccount {
            return provider.effectiveModelRoutes.map(\.modelID)
        }
        let urls = ProviderEndpointResolver.urls(
            baseURL: provider.baseURL,
            endpoint: "models"
        )
        guard !urls.isEmpty else { throw URLError(.badURL) }
        for url in urls {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            ProviderRequestAuthorizer.apply(
                ActiveProviderSnapshot(profile: provider, bearerToken: token),
                to: &request
            )
            let (data, response) = try await load(request)
            guard let response = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            if response.statusCode == 404 { continue }
            guard (200..<300).contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw URLError(.cannotParseResponse)
            }
            let rows = (root["data"] as? [[String: Any]])
                ?? (root["models"] as? [[String: Any]])
                ?? []
            return rows.compactMap { row in
                (row["id"] as? String) ?? (row["slug"] as? String) ?? (row["name"] as? String)
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .uniquedPreservingOrder()
        }
        throw URLError(.badServerResponse)
    }

    private static let probeName = "exec"
    private static let probePrompt = "Use the exec tool once with input pwd. Do not answer with text."
    private static let modelProbeTimeout: TimeInterval = 60
    private static let probeSchema: [String: Any] = [
        "type": "object",
        "properties": ["input": ["type": "string"]],
        "required": ["input"],
        "additionalProperties": false,
    ]

    private let load: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(session: URLSession = .shared) {
        load = { request in
            try await session.data(for: request)
        }
    }

    init(load: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.load = load
    }

    func measureEndpoint(
        provider: ProviderProfile,
        token: String?,
        chatGPTAccountID: String? = nil
    ) async -> ProviderHealthResult {
        if provider.credentialMode == .chatGPTAccount {
            let body = try? JSONSerialization.data(withJSONObject: [
                "model": provider.effectiveTestModel,
                "input": "Reply with OK.",
                "max_output_tokens": 16,
                "stream": false,
                "store": false,
            ])
            return await perform(
                provider: provider,
                token: token,
                chatGPTAccountID: chatGPTAccountID,
                endpoint: "responses",
                body: body
            )
        }
        return await perform(
            provider: provider,
            token: token,
            chatGPTAccountID: chatGPTAccountID,
            endpoint: "models",
            body: nil
        )
    }

    func testModel(
        provider: ProviderProfile,
        token: String?,
        chatGPTAccountID: String? = nil
    ) async -> ProviderHealthResult {
        let validator: @Sendable (Data) -> String? = { data in
            Self.nativeToolCallError(in: data, protocol: provider.wireProtocol)
        }
        switch provider.wireProtocol {
        case .chatCompletions:
            var object: [String: Any] = [
                "model": provider.effectiveTestModel,
                "messages": [["role": "user", "content": Self.probePrompt]],
                "tools": [[
                    "type": "function",
                    "function": [
                        "name": Self.probeName,
                        "description": "Verify native tool calling support.",
                        "parameters": Self.probeSchema,
                    ],
                ]],
                "max_tokens": 64,
                "stream": false,
            ]
            if provider.chatDialect != .standard {
                object["thinking"] = ["type": "disabled"]
            }
            let body = try? JSONSerialization.data(withJSONObject: object)
            return await perform(
                provider: provider,
                token: token,
                chatGPTAccountID: chatGPTAccountID,
                endpoint: "chat/completions",
                body: body,
                timeoutInterval: Self.modelProbeTimeout,
                validate: validator
            )
        case .anthropicMessages:
            let body = try? JSONSerialization.data(withJSONObject: [
                "model": provider.effectiveTestModel,
                "system": "Use tools only through native tool_use blocks. Never write tool calls as XML or JSON text.",
                "messages": [["role": "user", "content": Self.probePrompt]],
                "tools": [[
                    "name": Self.probeName,
                    "description": "Verify native tool calling support.",
                    "input_schema": Self.probeSchema,
                ]],
                "tool_choice": ["type": "tool", "name": Self.probeName],
                "max_tokens": 1_025,
                "stream": false,
            ])
            return await perform(
                provider: provider,
                token: token,
                chatGPTAccountID: chatGPTAccountID,
                endpoint: "messages",
                body: body,
                timeoutInterval: Self.modelProbeTimeout,
                validate: validator
            )
        case .responses:
            let body = try? JSONSerialization.data(withJSONObject: [
                "model": provider.effectiveTestModel,
                "input": [[
                    "role": "user",
                    "content": [[
                        "type": "input_text",
                        "text": Self.probePrompt,
                    ]],
                ]],
                "tools": [[
                    "type": "function",
                    "name": Self.probeName,
                    "description": "Verify native tool calling support.",
                    "parameters": Self.probeSchema,
                    "strict": true,
                ]],
                "max_output_tokens": 64,
                "stream": false,
                "store": false,
            ])
            return await perform(
                provider: provider,
                token: token,
                chatGPTAccountID: chatGPTAccountID,
                endpoint: "responses",
                body: body,
                timeoutInterval: Self.modelProbeTimeout,
                validate: validator
            )
        }
    }

    private func perform(
        provider: ProviderProfile,
        token: String?,
        chatGPTAccountID: String?,
        endpoint: String,
        body: Data?,
        timeoutInterval: TimeInterval = 15,
        validate: (@Sendable (Data) -> String?)? = nil
    ) async -> ProviderHealthResult {
        let urls = ProviderEndpointResolver.urls(baseURL: provider.baseURL, endpoint: endpoint)
        guard !urls.isEmpty else {
            return ProviderHealthResult(state: .unavailable, latencyMilliseconds: 0, statusCode: nil, message: "无效的 Provider 地址")
        }
        let startedAt = Date()
        for (index, url) in urls.enumerated() {
            var request = URLRequest(url: url)
            request.httpMethod = body == nil ? "GET" : "POST"
            request.httpBody = body
            request.timeoutInterval = max(1, timeoutInterval - Date().timeIntervalSince(startedAt))
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            ProviderRequestAuthorizer.apply(
                ActiveProviderSnapshot(
                    profile: provider,
                    bearerToken: token,
                    chatGPTAccountID: chatGPTAccountID
                ),
                to: &request
            )
            if provider.wireProtocol == .anthropicMessages {
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            }

            do {
                let (data, response) = try await load(request)
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
                guard let response = response as? HTTPURLResponse else {
                    return ProviderHealthResult(state: .unavailable, latencyMilliseconds: elapsed, statusCode: nil, message: "上游响应格式无效")
                }
                if (200..<300).contains(response.statusCode) {
                    if let message = validate?(data) {
                        return ProviderHealthResult(
                            state: .unavailable,
                            latencyMilliseconds: elapsed,
                            statusCode: response.statusCode,
                            message: message
                        )
                    }
                    return ProviderHealthResult(
                        state: elapsed > 6_000 ? .degraded : .healthy,
                        latencyMilliseconds: elapsed,
                        statusCode: response.statusCode,
                        message: nil
                    )
                }
                if index < urls.count - 1, [404, 405].contains(response.statusCode) {
                    continue
                }
                return ProviderHealthResult(
                    state: .unavailable,
                    latencyMilliseconds: elapsed,
                    statusCode: response.statusCode,
                    message: Self.httpErrorMessage(statusCode: response.statusCode, data: data)
                )
            } catch let error as URLError {
                let message = error.code == .timedOut
                    ? "检测超时（\(Int(timeoutInterval)) 秒）"
                    : "网络请求失败"
                return ProviderHealthResult(
                    state: .unavailable,
                    latencyMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
                    statusCode: nil,
                    message: message
                )
            } catch {
                return ProviderHealthResult(
                    state: .unavailable,
                    latencyMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
                    statusCode: nil,
                    message: "检测失败"
                )
            }
        }
        return ProviderHealthResult(state: .unavailable, latencyMilliseconds: 0, statusCode: nil, message: "检测失败")
    }

    private static func nativeToolCallError(
        in data: Data,
        protocol wireProtocol: ProviderWireProtocol
    ) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "模型未返回可解析的原生工具调用，无法用于 Codex"
        }
        let returnedName: String?
        let returnedInput: String?
        switch wireProtocol {
        case .responses:
            let output = root["output"] as? [[String: Any]] ?? []
            let call = output.first(where: { $0["type"] as? String == "function_call" })
            returnedName = call?["name"] as? String
            returnedInput = decodedProbeInput(call?["arguments"])
        case .chatCompletions:
            let choices = root["choices"] as? [[String: Any]] ?? []
            let message = choices.first?["message"] as? [String: Any]
            let calls = message?["tool_calls"] as? [[String: Any]] ?? []
            let function = calls.first?["function"] as? [String: Any]
            returnedName = function?["name"] as? String
            returnedInput = decodedProbeInput(function?["arguments"])
        case .anthropicMessages:
            let content = root["content"] as? [[String: Any]] ?? []
            let call = content.first(where: { $0["type"] as? String == "tool_use" })
            returnedName = call?["name"] as? String
            returnedInput = (call?["input"] as? [String: Any])?["input"] as? String
        }
        return returnedName == probeName && returnedInput?.isEmpty == false
            ? nil
            : "模型不支持原生结构化工具调用，无法用于 Codex"
    }

    private static func decodedProbeInput(_ arguments: Any?) -> String? {
        if let object = arguments as? [String: Any] {
            return object["input"] as? String
        }
        guard let string = arguments as? String,
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["input"] as? String
    }

    private static func httpErrorMessage(statusCode: Int, data: Data) -> String {
        let prefix = "HTTP \(statusCode)"
        guard !data.isEmpty else { return prefix }
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let detail = ((root?["error"] as? [String: Any])?["message"] as? String)
            ?? (root?["message"] as? String)
            ?? (root?["detail"] as? String)
            ?? String(data: data, encoding: .utf8)
        guard let detail else { return prefix }
        let normalized = detail
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return prefix }
        return "\(prefix)：\(String(normalized.prefix(300)))"
    }
}

enum ProviderEndpointResolver {
    static func urls(baseURL: String, endpoint: String) -> [URL] {
        guard let primary = endpointURL(baseURL: baseURL, pathComponents: [endpoint]) else { return [] }
        guard endpoint == "models",
              primary.pathComponents.dropLast().last?.lowercased() != "v1",
              let fallback = endpointURL(baseURL: baseURL, pathComponents: ["v1", endpoint]),
              fallback != primary else {
            return [primary]
        }
        return [primary, fallback]
    }

    private static func endpointURL(baseURL: String, pathComponents: [String]) -> URL? {
        guard let base = URL(string: baseURL),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let path = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = pathComponents.joined(separator: "/")
        components.path = path.isEmpty ? "/\(suffix)" : "/\(path)/\(suffix)"
        components.query = nil
        return components.url
    }
}

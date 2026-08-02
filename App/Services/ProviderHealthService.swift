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
            // ChatGPT 账号后端强制要求 stream=true，否则返回 HTTP 400
            // "Stream must be set to true"；且不接受 max_output_tokens 等
            // Responses API 通用参数（返回 "Unsupported parameter"）。
            // 因此探针以流式发起，仅携带后端认可的字段，并在
            // nativeToolCallError 中解析 SSE 事件提取 function_call。
            let body = try? JSONSerialization.data(withJSONObject: Self.chatGPTProbeBody(
                model: provider.effectiveTestModel,
                input: [[
                    "role": "user",
                    "content": [["type": "input_text", "text": "Reply with OK."]],
                ]]
            ))
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
            let body: Data?
            if provider.credentialMode == .chatGPTAccount {
                // ChatGPT 账号后端：stream 必须为 true，且不接受 max_output_tokens。
                body = try? JSONSerialization.data(withJSONObject: Self.chatGPTProbeBody(
                    model: provider.effectiveTestModel,
                    input: [[
                        "role": "user",
                        "content": [["type": "input_text", "text": Self.probePrompt]],
                    ]],
                    tools: [[
                        "type": "function",
                        "name": Self.probeName,
                        "description": "Verify native tool calling support.",
                        "parameters": Self.probeSchema,
                        "strict": true,
                    ]]
                ))
            } else {
                body = try? JSONSerialization.data(withJSONObject: [
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
            }
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
            // 显式要求 identity 编码：部分上游（如 ChatGPT 账号后端）可能返回
            // brotli，URLSession 不会自动解压 brotli，会导致探针拿到二进制乱码、
            // 解析失败。要求 identity 规避该问题。
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
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
        guard let root = parseProbePayload(data) else {
            return "模型未返回可解析的原生工具调用，无法用于 Codex"
        }
        let returnedName: String?
        let returnedInput: String?
        switch wireProtocol {
        case .responses:
            // Responses 既可能返回非流式 JSON（{ "output": [...] }），
            // 也可能返回 SSE 事件流（ChatGPT 账号要求 stream=true）。
            // 递归查找首个 function_call 即可同时覆盖两种形态。
            let call = findFunctionCall(in: root)
            returnedName = call?["name"] as? String
            returnedInput = decodedProbeInput(call?["arguments"])
        case .chatCompletions:
            let root = root as? [String: Any] ?? [:]
            let choices = root["choices"] as? [[String: Any]] ?? []
            let message = choices.first?["message"] as? [String: Any]
            let calls = message?["tool_calls"] as? [[String: Any]] ?? []
            let function = calls.first?["function"] as? [String: Any]
            returnedName = function?["name"] as? String
            returnedInput = decodedProbeInput(function?["arguments"])
        case .anthropicMessages:
            let root = root as? [String: Any] ?? [:]
            let content = root["content"] as? [[String: Any]] ?? []
            let call = content.first(where: { $0["type"] as? String == "tool_use" })
            returnedName = call?["name"] as? String
            returnedInput = (call?["input"] as? [String: Any])?["input"] as? String
        }
        return returnedName == probeName && returnedInput?.isEmpty == false
            ? nil
            : "模型不支持原生结构化工具调用，无法用于 Codex"
    }

    /// ChatGPT 账号探针请求体：仅携带后端认可的字段。
    /// 实测约束：stream 必须为 true、store 必须为 false、input 必须为数组形态、
    /// 不接受 max_output_tokens（这些不满足时后端返回 HTTP 400）。
    private static func chatGPTProbeBody(
        model: String,
        input: Any,
        tools: [[String: Any]]? = nil
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "input": input,
            "stream": true,
            "store": false,
        ]
        if let tools { body["tools"] = tools }
        return body
    }

    /// 解析探针响应：兼容非流式 JSON 与 SSE 事件流。
    private static func parseProbePayload(_ data: Data) -> Any? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return try? JSONSerialization.jsonObject(with: data)
        }
        // SSE：逐行提取 "data:" 负载并解析为 JSON 对象。
        var events: [Any] = []
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]",
                  let eventData = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: eventData) else {
                continue
            }
            events.append(event)
        }
        return events.isEmpty ? nil : events
    }

    /// 在任意 JSON 结构中递归查找 function_call 项。
    /// SSE 流中同一 function_call 会先以 `response.output_item.added` 出现
    /// （arguments 为空串），随后才以 `response.output_item.done` 出现
    /// （arguments 为完整参数）。优先返回 arguments 可解出非空 input 的那个，
    /// 否则回退到首个命中的 function_call。
    private static func findFunctionCall(in value: Any) -> [String: Any]? {
        var best: [String: Any]?
        var fallback: [String: Any]?
        func search(_ v: Any) {
            if let dictionary = v as? [String: Any] {
                if dictionary["type"] as? String == "function_call" {
                    fallback = dictionary
                    if decodedProbeInput(dictionary["arguments"])?.isEmpty == false {
                        best = dictionary
                    }
                }
                for nested in dictionary.values { search(nested) }
            } else if let array = v as? [Any] {
                for nested in array { search(nested) }
            }
        }
        search(value)
        return best ?? fallback
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

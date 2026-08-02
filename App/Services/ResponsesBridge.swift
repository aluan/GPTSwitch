import Foundation

enum ResponsesBridgeError: LocalizedError {
    case invalidImagesRequest
    case invalidUpstreamResponse
    case missingImageResult
    case upstreamFailure(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidImagesRequest: "Images 请求缺少有效 prompt"
        case .invalidUpstreamResponse: "无法解析上游 Responses 响应"
        case .missingImageResult: "Responses 返回中没有 image_generation_call.result"
        case .upstreamFailure(let status, let message): "上游返回 HTTP \(status)：\(message)"
        }
    }
}

struct ResponsesBridge: Sendable {
    struct ImageResult {
        let base64: String
        let metadata: [String: Any]
        let observation: ResponseUsageObservation
    }

    func makeResponsesRequest(
        from request: IncomingHTTPRequest,
        configuration: ProxyConfiguration,
        edit: Bool
    ) throws -> URLRequest {
        let profile = ProviderProfile(
            configName: configuration.providerName,
            displayName: configuration.providerName,
            baseURL: configuration.upstreamBaseURL,
            bridgeModel: configuration.bridgeModel,
            credentialMode: .passthrough
        )
        return try makeResponsesRequest(
            from: request,
            provider: ActiveProviderSnapshot(profile: profile, bearerToken: nil),
            edit: edit
        )
    }

    func makeResponsesRequest(
        from request: IncomingHTTPRequest,
        provider: ActiveProviderSnapshot,
        edit: Bool
    ) throws -> URLRequest {
        guard let object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let prompt = object["prompt"] as? String,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResponsesBridgeError.invalidImagesRequest
        }
        var content: [[String: Any]] = [["type": "input_text", "text": prompt]]
        if edit, let images = object["images"] as? [[String: Any]] {
            for image in images {
                if let imageURL = image["image_url"] as? String, !imageURL.isEmpty {
                    content.append(["type": "input_image", "image_url": imageURL, "detail": "high"])
                }
            }
        }
        // ChatGPT 账号后端强制 stream=true（否则 HTTP 400 "Stream must be set
        // to true"），其他 Responses 提供商沿用非流式以便直接解析 JSON。
        let requiresStream = provider.profile.credentialMode == .chatGPTAccount
        let payload: [String: Any] = [
            "model": provider.bridgeModel,
            "input": [["role": "user", "content": content]],
            "tools": [["type": "image_generation", "output_format": "png"]],
            "tool_choice": ["type": "image_generation"],
            "stream": requiresStream,
            "store": false,
        ]
        let upstreamURL = try responsesURL(provider.upstreamBaseURL)
        var upstreamRequest = URLRequest(url: upstreamURL)
        upstreamRequest.httpMethod = "POST"
        upstreamRequest.timeoutInterval = 600
        upstreamRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)
        copyForwardableHeaders(from: request, to: &upstreamRequest)
        ProviderRequestAuthorizer.apply(provider, to: &upstreamRequest)
        upstreamRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstreamRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        upstreamRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return upstreamRequest
    }

    func parseImageResult(data: Data, contentType: String?) throws -> ImageResult {
        let root = try parseResponseRoot(data: data, contentType: contentType)
        guard let call = findImageCall(in: root),
              let result = call["result"] as? String,
              !result.isEmpty else {
            throw ResponsesBridgeError.missingImageResult
        }
        return ImageResult(
            base64: result,
            metadata: call,
            observation: UsageExtractor.observation(from: root)
        )
    }

    func makeImagesResponse(
        imageResult: ImageResult,
        originalBody: Data
    ) throws -> Data {
        let original = (try? JSONSerialization.jsonObject(with: originalBody)) as? [String: Any] ?? [:]
        var output: [String: Any] = [
            "created": Int(Date().timeIntervalSince1970),
            "data": [["b64_json": imageResult.base64]],
        ]
        for key in ["background", "quality", "size"] {
            if let value = imageResult.metadata[key] ?? original[key] {
                output[key] = value
            }
        }
        return try JSONSerialization.data(withJSONObject: output)
    }

    private func parseResponseRoot(data: Data, contentType: String?) throws -> Any {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ResponsesBridgeError.invalidUpstreamResponse
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return try JSONSerialization.jsonObject(with: data)
        }
        // ChatGPT 账号后端以 SSE 返回，但响应头往往不带 Content-Type（实测为
        // nil），因此既按声明类型、也按内容（"data:" / "event:" 行）识别 SSE。
        let declaredSSE = contentType?.lowercased().contains("text/event-stream") == true
        let looksLikeSSE = trimmed.hasPrefix("event:") || trimmed.hasPrefix("data:")
        guard declaredSSE || looksLikeSSE else {
            throw ResponsesBridgeError.invalidUpstreamResponse
        }
        var events: [Any] = []
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let eventData = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: eventData) else {
                continue
            }
            events.append(event)
        }
        guard !events.isEmpty else {
            throw ResponsesBridgeError.invalidUpstreamResponse
        }
        return events
    }

    private func findImageCall(in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if dictionary["type"] as? String == "image_generation_call",
               dictionary["result"] is String {
                return dictionary
            }
            for nested in dictionary.values {
                if let result = findImageCall(in: nested) {
                    return result
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let result = findImageCall(in: nested) {
                    return result
                }
            }
        }
        return nil
    }

    private func responsesURL(_ baseURL: String) throws -> URL {
        guard let base = URL(string: baseURL), var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw ResponsesBridgeError.invalidImagesRequest
        }
        components.path = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            ? "/responses"
            : "/\(base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/responses"
        guard let url = components.url else {
            throw ResponsesBridgeError.invalidImagesRequest
        }
        return url
    }

    private func copyForwardableHeaders(from request: IncomingHTTPRequest, to output: inout URLRequest) {
        let excluded = Set([
            "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
            "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade",
            "host", "content-length",
        ])
        for (name, value) in request.headers where !excluded.contains(name.lowercased()) {
            output.setValue(value, forHTTPHeaderField: name)
        }
    }
}

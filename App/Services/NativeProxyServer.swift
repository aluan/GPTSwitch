import Foundation
import Network

final class NativeProxyServer: @unchecked Sendable {
    private let installConfiguration: ProxyConfiguration
    private let providerRouter: ActiveProviderRouter
    private let queue = DispatchQueue(label: "com.aluan.CodexImageGenProxy.server", qos: .userInitiated)
    private let eventHandler: @Sendable (RequestMetric) -> Void
    private let stateHandler: @Sendable (Result<Void, Error>) -> Void
    private var listener: NWListener?

    init(
        configuration: ProxyConfiguration,
        providerRouter: ActiveProviderRouter,
        eventHandler: @escaping @Sendable (RequestMetric) -> Void,
        stateHandler: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        installConfiguration = configuration
        self.providerRouter = providerRouter
        self.eventHandler = eventHandler
        self.stateHandler = stateHandler
    }

    func start() throws {
        guard let port = NWEndpoint.Port(rawValue: installConfiguration.port) else {
            throw URLError(.badURL)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.stateHandler(.success(()))
                AppLog.info("Native proxy listening on 127.0.0.1:\(port.rawValue)")
            case .failed(let error):
                self?.stateHandler(.failure(error))
                AppLog.error("Proxy listener failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            ClientConnectionHandler(
                connection: connection,
                queue: self.queue,
                requestHandler: { [weak self] request, connection in
                    self?.handle(request, connection: connection)
                }
            ).start()
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        AppLog.info("Native proxy stopped")
    }

    private func handle(_ request: IncomingHTTPRequest, connection: NWConnection) {
        let defaultProvider = providerRouter.snapshot()
        if request.path == "/_codex_imagegen_patch/health" {
            HTTPResponseWriter.sendJSON(
                status: 200,
                object: [
                    "ok": true,
                    "tool_version": ProxyConfiguration.currentToolVersion,
                    "bridge_model": defaultProvider.profile.wireProtocol == .responses
                        ? defaultProvider.bridgeModel
                        : defaultProvider.inferenceModel,
                    "provider": defaultProvider.profile.displayName,
                ],
                to: connection
            )
            return
        }
        let normalizedPath = request.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if request.method == "GET", normalizedPath.hasSuffix("models") {
            serveModels(request, connection: connection)
            return
        }
        if normalizedPath.hasSuffix("images/generations") {
            if defaultProvider.profile.supportsImageBridge {
                bridge(request, provider: defaultProvider, edit: false, connection: connection)
            } else {
                unsupportedImages(connection: connection)
            }
        } else if normalizedPath.hasSuffix("images/edits") {
            if defaultProvider.profile.supportsImageBridge {
                bridge(request, provider: defaultProvider, edit: true, connection: connection)
            } else {
                unsupportedImages(connection: connection)
            }
        } else {
            do {
                let metadata = UsageExtractor.requestMetadata(from: request.body)
                let provider = try providerRouter.route(model: metadata.model)
                if provider.profile.wireProtocol != .responses,
                   normalizedPath.hasSuffix("responses/compact") {
                    HTTPResponseWriter.error(
                        status: 501,
                        message: "当前 Provider 不支持远程 Responses Compaction",
                        to: connection
                    )
                } else if provider.profile.wireProtocol == .chatCompletions,
                          request.method == "POST",
                          normalizedPath.hasSuffix("responses") {
                    bridgeTranslated(
                        request,
                        provider: provider,
                        adapter: ChatCompletionsBridge(),
                        connection: connection
                    )
                } else if provider.profile.wireProtocol == .anthropicMessages,
                          request.method == "POST",
                          normalizedPath.hasSuffix("responses") {
                    bridgeTranslated(
                        request,
                        provider: provider,
                        adapter: AnthropicMessagesBridge(),
                        connection: connection
                    )
                } else {
                    forward(request, provider: provider, connection: connection)
                }
            } catch let error as ProviderRoutingError {
                HTTPResponseWriter.error(status: 400, message: error.localizedDescription, to: connection)
            } catch {
                HTTPResponseWriter.error(status: 502, message: error.localizedDescription, to: connection)
            }
        }
    }

    private func serveModels(_ request: IncomingHTTPRequest, connection: NWConnection) {
        do {
            let query = URLComponents(string: request.target)?.queryItems ?? []
            let codexShape = query.contains { $0.name == "client_version" }
            let data = try CodexModelCatalogService().modelsResponse(
                provider: providerRouter.snapshot().profile,
                codexShape: codexShape,
                crossProvider: providerRouter.isCrossProviderRoutingEnabled()
            )
            HTTPResponseWriter.send(
                status: 200,
                contentType: "application/json; charset=utf-8",
                body: data,
                to: connection
            )
        } catch {
            HTTPResponseWriter.error(status: 502, message: error.localizedDescription, to: connection)
        }
    }

    private func unsupportedImages(connection: NWConnection) {
        HTTPResponseWriter.sendJSON(
            status: 501,
            object: ["error": [
                "message": "当前 Provider 不支持 Images API",
                "type": "provider_does_not_support_images",
            ]],
            to: connection
        )
    }

    /// 诊断：dump 进入请求（Codex 原始体），用于排查工具目录是否被客户端发送。
    #if DEBUG
    /// 诊断：dump 进入请求（Codex 原始体），用于排查工具目录是否被客户端发送。
    private static func dumpIncoming(request: IncomingHTTPRequest, provider: ActiveProviderSnapshot) {
        let dir = AppPaths.logs.appendingPathComponent("diag")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var report = "=== provider: \(provider.profile.displayName) / \(provider.inferenceModel) ===\n"
        report += "########## INCOMING REQUEST (from Codex CLI, pre-bridge) ##########\n"
        if let obj = try? JSONSerialization.jsonObject(with: request.body),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            report += String(decoding: pretty, as: UTF8.self)
        } else {
            report += String(decoding: request.body, as: UTF8.self)
        }
        report += "\n"
        let stamp = String(Int(Date().timeIntervalSince1970))
        try? report.write(to: dir.appendingPathComponent("incoming-\(stamp).log"), atomically: true, encoding: .utf8)
        try? report.write(to: dir.appendingPathComponent("incoming-latest.log"), atomically: true, encoding: .utf8)
    }
    #endif

    private func bridgeTranslated(
        _ request: IncomingHTTPRequest,
        provider: ActiveProviderSnapshot,
        adapter: any ProviderAdapter,
        connection: NWConnection
    ) {
        let startedAt = Date()
        let metadata = UsageExtractor.requestMetadata(from: request.body)
        #if DEBUG
        Self.dumpIncoming(request: request, provider: provider)
        #endif
        do {
            let parsed = try ResponsesRequestParser().parse(request)
            let adapterRequest = try adapter.makeRequest(parsed: parsed, incoming: request, provider: provider)
            let delegate = AdapterStreamingForwardDelegate(
                connection: connection,
                provider: provider,
                requestMetadata: metadata,
                startedAt: startedAt,
                adapterRequest: adapterRequest,
                adapter: adapter
            ) { [eventHandler] metric in
                eventHandler(metric)
            }
            delegate.start()
        } catch {
            let status = error is ModelProtocolError ? 400 : 502
            HTTPResponseWriter.error(status: status, message: error.localizedDescription, to: connection)
            eventHandler(makeMetric(
                startedAt: startedAt,
                provider: provider,
                endpoint: .responses,
                requestMetadata: metadata,
                observation: ResponseUsageObservation(),
                statusCode: status,
                imageCount: 0,
                errorCategory: error is ModelProtocolError ? "adapter_request_error" : "proxy_error"
            ))
        }
    }

    private func bridge(
        _ request: IncomingHTTPRequest,
        provider: ActiveProviderSnapshot,
        edit: Bool,
        connection: NWConnection
    ) {
        let startedAt = Date()
        let requestMetadata = UsageExtractor.requestMetadata(from: request.body)
        Task {
            var upstreamStatus: Int?
            do {
                let bridge = ResponsesBridge()
                let upstreamRequest = try bridge.makeResponsesRequest(
                    from: request,
                    provider: provider,
                    edit: edit
                )
                let (data, response) = try await URLSession.shared.data(for: upstreamRequest)
                guard let response = response as? HTTPURLResponse else {
                    throw ResponsesBridgeError.invalidUpstreamResponse
                }
                upstreamStatus = response.statusCode
                guard (200..<300).contains(response.statusCode) else {
                    throw ResponsesBridgeError.upstreamFailure(
                        response.statusCode,
                        upstreamErrorMessage(statusCode: response.statusCode, data: data)
                            ?? "上游请求失败"
                    )
                }
                let result = try bridge.parseImageResult(
                    data: data,
                    contentType: response.value(forHTTPHeaderField: "Content-Type")
                )
                let output = try bridge.makeImagesResponse(imageResult: result, originalBody: request.body)
                HTTPResponseWriter.send(
                    status: 200,
                    contentType: "application/json; charset=utf-8",
                    body: output,
                    to: connection
                )
                eventHandler(makeMetric(
                    startedAt: startedAt,
                    provider: provider,
                    endpoint: edit ? .imageEdit : .imageGeneration,
                    requestMetadata: requestMetadata,
                    observation: result.observation,
                    statusCode: response.statusCode,
                    imageCount: 1,
                    errorCategory: nil
                ))
            } catch {
                HTTPResponseWriter.error(status: 502, message: error.localizedDescription, to: connection)
                eventHandler(makeMetric(
                    startedAt: startedAt,
                    provider: provider,
                    endpoint: edit ? .imageEdit : .imageGeneration,
                    requestMetadata: requestMetadata,
                    observation: ResponseUsageObservation(),
                    statusCode: upstreamStatus,
                    imageCount: 0,
                    errorCategory: errorCategory(for: error, statusCode: upstreamStatus)
                ))
                AppLog.error("Image bridge failed: \(error.localizedDescription)")
            }
        }
    }

    private func forward(
        _ request: IncomingHTTPRequest,
        provider: ActiveProviderSnapshot,
        connection: NWConnection
    ) {
        let startedAt = Date()
        let metadata = UsageExtractor.requestMetadata(from: request.body)
        let endpoint = requestEndpoint(for: request.path)
        do {
            let upstreamRequest = try makeForwardRequest(request, provider: provider)
            let delegate = StreamingForwardDelegate(
                connection: connection,
                provider: provider,
                endpoint: endpoint,
                requestMetadata: metadata,
                startedAt: startedAt
            ) { [eventHandler] metric in
                eventHandler(metric)
            }
            delegate.start(request: upstreamRequest)
        } catch {
            HTTPResponseWriter.error(status: 502, message: error.localizedDescription, to: connection)
            eventHandler(makeMetric(
                startedAt: startedAt,
                provider: provider,
                endpoint: endpoint,
                requestMetadata: metadata,
                observation: ResponseUsageObservation(),
                statusCode: nil,
                imageCount: 0,
                errorCategory: errorCategory(for: error, statusCode: nil)
            ))
        }
    }

    private func makeForwardRequest(
        _ request: IncomingHTTPRequest,
        provider: ActiveProviderSnapshot
    ) throws -> URLRequest {
        guard let upstream = URL(string: provider.upstreamBaseURL),
              var components = URLComponents(url: upstream, resolvingAgainstBaseURL: false),
              let incoming = URLComponents(string: request.target) else {
            throw URLError(.badURL)
        }
        let localBasePath = URL(string: installConfiguration.localBaseURL)?.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        var suffix = incoming.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !localBasePath.isEmpty {
            if suffix == localBasePath {
                suffix = ""
            } else if suffix.hasPrefix("\(localBasePath)/") {
                suffix.removeFirst(localBasePath.count + 1)
            }
        }
        let upstreamBasePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = [upstreamBasePath, suffix]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        if !components.path.isEmpty { components.path = "/\(components.path)" }
        components.query = incoming.query
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        var output = URLRequest(url: url)
        output.httpMethod = request.method
        output.httpBody = try rewrittenBody(request.body, model: provider.upstreamModelOverride)
        let excluded = Set([
            "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
            "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade",
            "host", "content-length",
        ])
        for (name, value) in request.headers where !excluded.contains(name.lowercased()) {
            output.setValue(value, forHTTPHeaderField: name)
        }
        ProviderRequestAuthorizer.apply(provider, to: &output)
        return output
    }

    private func rewrittenBody(_ body: Data, model: String?) throws -> Data? {
        guard !body.isEmpty else { return nil }
        guard let model else { return body }
        guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ModelProtocolError.invalidResponsesRequest
        }
        object["model"] = model
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func requestEndpoint(for path: String) -> RequestEndpoint {
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized.hasSuffix("/responses") || normalized == "responses" { return .responses }
        if normalized.hasSuffix("/models") || normalized == "models" { return .models }
        return .other
    }

    private func makeMetric(
        startedAt: Date,
        provider: ActiveProviderSnapshot,
        endpoint: RequestEndpoint,
        requestMetadata: RequestMetadata,
        observation: ResponseUsageObservation,
        statusCode: Int?,
        imageCount: Int,
        errorCategory: String?
    ) -> RequestMetric {
        let completedAt = Date()
        return RequestMetric(
            startedAt: startedAt,
            completedAt: completedAt,
            providerID: provider.id,
            providerName: provider.profile.displayName,
            endpoint: endpoint,
            requestedModel: requestMetadata.model,
            responseModel: observation.model ?? (endpoint == .imageGeneration || endpoint == .imageEdit ? provider.bridgeModel : nil),
            statusCode: statusCode,
            isStreaming: requestMetadata.isStreaming,
            durationMilliseconds: Int(completedAt.timeIntervalSince(startedAt) * 1_000),
            usage: observation.usage,
            imageCount: imageCount,
            errorCategory: errorCategory
        )
    }

    private func errorCategory(for error: Error, statusCode: Int?) -> String {
        if let statusCode { return "http_\(statusCode)" }
        if error is URLError { return "network_error" }
        if error is ResponsesBridgeError { return "bridge_error" }
        return "proxy_error"
    }

    /// 从上游 4xx/5xx 响应体里提取可读错误信息，便于定位。
    private func upstreamErrorMessage(statusCode: Int, data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let detail = ((root?["error"] as? [String: Any])?["message"] as? String)
            ?? (root?["message"] as? String)
            ?? (root?["detail"] as? String)
            ?? String(data: data, encoding: .utf8)
        guard let detail, !detail.isEmpty else { return nil }
        let normalized = detail.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(normalized.prefix(300))
    }
}

private final class ClientConnectionHandler: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let requestHandler: @Sendable (IncomingHTTPRequest, NWConnection) -> Void
    private var buffer = Data()
    private var expectedLength: Int?

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        requestHandler: @escaping @Sendable (IncomingHTTPRequest, NWConnection) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.requestHandler = requestHandler
    }

    func start() {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data {
                buffer.append(data)
            }
            do {
                if expectedLength == nil {
                    expectedLength = try HTTPRequestParser.expectedRequestLength(in: buffer)
                }
                if let expectedLength, buffer.count >= expectedLength {
                    let request = try HTTPRequestParser.parse(Data(buffer.prefix(expectedLength)))
                    requestHandler(request, connection)
                    return
                }
            } catch {
                HTTPResponseWriter.error(status: 400, message: error.localizedDescription, to: connection)
                return
            }
            if let error {
                AppLog.error("Client connection failed: \(error.localizedDescription)")
                connection.cancel()
            } else if isComplete {
                connection.cancel()
            } else {
                receive()
            }
        }
    }
}

private final class StreamingForwardDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: NWConnection
    private let provider: ActiveProviderSnapshot
    private let endpoint: RequestEndpoint
    private let requestMetadata: RequestMetadata
    private let startedAt: Date
    private let completion: @Sendable (RequestMetric) -> Void
    private let usageParser = StreamingUsageParser()
    private var session: URLSession?
    private var responseStarted = false
    private var statusCode: Int?
    private var firstByteAt: Date?

    init(
        connection: NWConnection,
        provider: ActiveProviderSnapshot,
        endpoint: RequestEndpoint,
        requestMetadata: RequestMetadata,
        startedAt: Date,
        completion: @escaping @Sendable (RequestMetric) -> Void
    ) {
        self.connection = connection
        self.provider = provider
        self.endpoint = endpoint
        self.requestMetadata = requestMetadata
        self.startedAt = startedAt
        self.completion = completion
    }

    func start(request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3_600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: request).resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        statusCode = response.statusCode
        usageParser.begin(contentType: response.value(forHTTPHeaderField: "Content-Type"))
        var header = "HTTP/1.1 \(response.statusCode) \(HTTPResponseWriter.reasonPhrase(response.statusCode))\r\n"
        let excluded = Set(["content-length", "transfer-encoding", "connection", "keep-alive"])
        for (rawName, rawValue) in response.allHeaderFields {
            let name = String(describing: rawName)
            guard !excluded.contains(name.lowercased()) else { continue }
            header += "\(name): \(rawValue)\r\n"
        }
        header += "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        responseStarted = true
        connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
            completionHandler(error == nil ? .allow : .cancel)
        })
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        if firstByteAt == nil { firstByteAt = Date() }
        usageParser.consume(data)
        var chunk = Data(String(data.count, radix: 16).utf8)
        chunk.append(Data("\r\n".utf8))
        chunk.append(data)
        chunk.append(Data("\r\n".utf8))
        connection.send(content: chunk, completion: .idempotent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            session.finishTasksAndInvalidate()
            self.session = nil
        }
        if let error {
            if responseStarted {
                connection.cancel()
            } else {
                HTTPResponseWriter.error(status: 502, message: error.localizedDescription, to: connection)
            }
            completion(makeMetric(errorCategory: "network_error"))
            return
        }
        connection.send(content: Data("0\r\n\r\n".utf8), contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { [completion] error in
            self.connection.cancel()
            completion(self.makeMetric(errorCategory: error == nil ? nil : "downstream_error"))
        })
    }

    private func makeMetric(errorCategory: String?) -> RequestMetric {
        let completedAt = Date()
        let observation = usageParser.finish()
        return RequestMetric(
            startedAt: startedAt,
            completedAt: completedAt,
            providerID: provider.id,
            providerName: provider.profile.displayName,
            endpoint: endpoint,
            requestedModel: requestMetadata.model,
            responseModel: observation.model,
            statusCode: statusCode,
            isStreaming: requestMetadata.isStreaming,
            durationMilliseconds: Int(completedAt.timeIntervalSince(startedAt) * 1_000),
            timeToFirstByteMilliseconds: firstByteAt.map { Int($0.timeIntervalSince(startedAt) * 1_000) },
            usage: observation.usage,
            errorCategory: errorCategory ?? statusCode.flatMap { (200..<300).contains($0) ? nil : "http_\($0)" }
        )
    }
}

private final class ChatStreamingForwardDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: NWConnection
    private let provider: ActiveProviderSnapshot
    private let requestMetadata: RequestMetadata
    private let startedAt: Date
    private let bridgeRequest: ChatBridgeRequest
    private let completion: @Sendable (RequestMetric) -> Void
    private let converter: ChatCompletionsStreamConverter
    private var session: URLSession?
    private var statusCode: Int?
    private var contentType: String?
    private var responseStarted = false
    private var firstByteAt: Date?
    private var bodyBuffer = Data()
    private var conversionError: Error?

    init(
        connection: NWConnection,
        provider: ActiveProviderSnapshot,
        requestMetadata: RequestMetadata,
        startedAt: Date,
        bridgeRequest: ChatBridgeRequest,
        completion: @escaping @Sendable (RequestMetric) -> Void
    ) {
        self.connection = connection
        self.provider = provider
        self.requestMetadata = requestMetadata
        self.startedAt = startedAt
        self.bridgeRequest = bridgeRequest
        self.completion = completion
        converter = ChatCompletionsStreamConverter(mappings: bridgeRequest.toolMappings)
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3_600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: bridgeRequest.urlRequest).resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        statusCode = response.statusCode
        contentType = response.value(forHTTPHeaderField: "Content-Type")
        if (200..<300).contains(response.statusCode), bridgeRequest.clientRequestedStreaming {
            var header = "HTTP/1.1 200 OK\r\n"
            header += "Content-Type: text/event-stream; charset=utf-8\r\n"
            header += "Cache-Control: no-cache\r\n"
            header += "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            responseStarted = true
            connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
                completionHandler(error == nil ? .allow : .cancel)
            })
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        if firstByteAt == nil { firstByteAt = Date() }
        guard (200..<300).contains(statusCode ?? 0), bridgeRequest.clientRequestedStreaming else {
            if bodyBuffer.count < UsageExtractor.maximumBufferedEventBytes {
                bodyBuffer.append(data.prefix(UsageExtractor.maximumBufferedEventBytes - bodyBuffer.count))
            }
            return
        }
        do {
            let converted = try converter.consume(data)
            sendChunk(converted)
        } catch {
            conversionError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            session.finishTasksAndInvalidate()
            self.session = nil
        }
        if let failure = conversionError ?? error {
            if responseStarted {
                sendChunk(failureEvent(message: failure.localizedDescription))
                finishChunks(errorCategory: "invalid_upstream_sse")
            } else {
                HTTPResponseWriter.error(status: 502, message: failure.localizedDescription, to: connection)
                completion(makeMetric(observation: ResponseUsageObservation(), errorCategory: "network_error"))
            }
            return
        }
        guard (200..<300).contains(statusCode ?? 0) else {
            let limited = Data(bodyBuffer.prefix(4 * 1024))
            HTTPResponseWriter.send(
                status: statusCode ?? 502,
                contentType: contentType ?? "application/json; charset=utf-8",
                body: limited,
                to: connection
            )
            completion(makeMetric(
                observation: ResponseUsageObservation(),
                errorCategory: "http_\(statusCode ?? 502)"
            ))
            return
        }
        if bridgeRequest.clientRequestedStreaming {
            do {
                sendChunk(try converter.finish())
                finishChunks(errorCategory: nil)
            } catch {
                sendChunk(failureEvent(message: "Invalid upstream stream"))
                finishChunks(errorCategory: "invalid_upstream_sse")
            }
        } else {
            do {
                let output = try ChatCompletionsBridge().makeNonStreamingResponse(
                    data: bodyBuffer,
                    mappings: bridgeRequest.toolMappings
                )
                let observation = UsageExtractor.observation(from: output, contentType: "application/json")
                HTTPResponseWriter.send(
                    status: 200,
                    contentType: "application/json; charset=utf-8",
                    body: output,
                    to: connection
                )
                completion(makeMetric(observation: observation, errorCategory: nil))
            } catch {
                HTTPResponseWriter.error(status: 502, message: error.localizedDescription, to: connection)
                completion(makeMetric(observation: ResponseUsageObservation(), errorCategory: "chat_bridge_error"))
            }
        }
    }

    private func sendChunk(_ data: Data) {
        guard !data.isEmpty else { return }
        var chunk = Data(String(data.count, radix: 16).utf8)
        chunk.append(Data("\r\n".utf8))
        chunk.append(data)
        chunk.append(Data("\r\n".utf8))
        connection.send(content: chunk, completion: .idempotent)
    }

    private func failureEvent(message: String) -> Data {
        let object: [String: Any] = [
            "type": "response.failed",
            "response": ["error": ["message": message]],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: object) else { return Data() }
        var output = Data("event: response.failed\ndata: ".utf8)
        output.append(payload)
        output.append(Data("\n\n".utf8))
        return output
    }

    private func finishChunks(errorCategory: String?) {
        connection.send(
            content: Data("0\r\n\r\n".utf8),
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [completion] downstreamError in
                self.connection.cancel()
                completion(self.makeMetric(
                    observation: self.converter.observation,
                    errorCategory: errorCategory ?? (downstreamError == nil ? nil : "downstream_error")
                ))
            }
        )
    }

    private func makeMetric(
        observation: ResponseUsageObservation,
        errorCategory: String?
    ) -> RequestMetric {
        let completedAt = Date()
        return RequestMetric(
            startedAt: startedAt,
            completedAt: completedAt,
            providerID: provider.id,
            providerName: provider.profile.displayName,
            endpoint: .responses,
            requestedModel: requestMetadata.model,
            responseModel: observation.model ?? provider.inferenceModel,
            statusCode: statusCode,
            isStreaming: requestMetadata.isStreaming,
            durationMilliseconds: Int(completedAt.timeIntervalSince(startedAt) * 1_000),
            timeToFirstByteMilliseconds: firstByteAt.map { Int($0.timeIntervalSince(startedAt) * 1_000) },
            usage: observation.usage,
            errorCategory: errorCategory
        )
    }
}

private final class AnthropicStreamingForwardDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: NWConnection
    private let provider: ActiveProviderSnapshot
    private let requestMetadata: RequestMetadata
    private let startedAt: Date
    private let bridgeRequest: AnthropicBridgeRequest
    private let completion: @Sendable (RequestMetric) -> Void
    private let converter: AnthropicMessagesStreamConverter
    private var session: URLSession?
    private var statusCode: Int?
    private var contentType: String?
    private var responseStarted = false
    private var firstByteAt: Date?
    private var bodyBuffer = Data()
    private var conversionError: Error?

    init(
        connection: NWConnection,
        provider: ActiveProviderSnapshot,
        requestMetadata: RequestMetadata,
        startedAt: Date,
        bridgeRequest: AnthropicBridgeRequest,
        completion: @escaping @Sendable (RequestMetric) -> Void
    ) {
        self.connection = connection
        self.provider = provider
        self.requestMetadata = requestMetadata
        self.startedAt = startedAt
        self.bridgeRequest = bridgeRequest
        self.completion = completion
        converter = AnthropicMessagesStreamConverter(mappings: bridgeRequest.toolMappings)
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3_600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: bridgeRequest.urlRequest).resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        statusCode = response.statusCode
        contentType = response.value(forHTTPHeaderField: "Content-Type")
        if (200..<300).contains(response.statusCode), bridgeRequest.clientRequestedStreaming {
            var header = "HTTP/1.1 200 OK\r\n"
            header += "Content-Type: text/event-stream; charset=utf-8\r\n"
            header += "Cache-Control: no-cache\r\n"
            header += "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            responseStarted = true
            connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
                completionHandler(error == nil ? .allow : .cancel)
            })
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        if firstByteAt == nil { firstByteAt = Date() }
        guard (200..<300).contains(statusCode ?? 0), bridgeRequest.clientRequestedStreaming else {
            if bodyBuffer.count < UsageExtractor.maximumBufferedEventBytes {
                bodyBuffer.append(data.prefix(UsageExtractor.maximumBufferedEventBytes - bodyBuffer.count))
            }
            return
        }
        do {
            sendChunk(try converter.consume(data))
        } catch {
            conversionError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            session.finishTasksAndInvalidate()
            self.session = nil
        }
        if let failure = conversionError ?? error {
            if responseStarted {
                sendChunk(failureEvent(message: failure.localizedDescription))
                finishChunks(errorCategory: "invalid_upstream_sse")
            } else {
                HTTPResponseWriter.error(status: 502, message: failure.localizedDescription, to: connection)
                completion(makeMetric(observation: ResponseUsageObservation(), errorCategory: "network_error"))
            }
            return
        }
        guard (200..<300).contains(statusCode ?? 0) else {
            let limited = Data(bodyBuffer.prefix(4 * 1024))
            HTTPResponseWriter.send(
                status: statusCode ?? 502,
                contentType: contentType ?? "application/json; charset=utf-8",
                body: limited,
                to: connection
            )
            completion(makeMetric(
                observation: ResponseUsageObservation(),
                errorCategory: "http_\(statusCode ?? 502)"
            ))
            return
        }
        if bridgeRequest.clientRequestedStreaming {
            do {
                sendChunk(try converter.finish())
                finishChunks(errorCategory: nil)
            } catch {
                sendChunk(failureEvent(message: "Invalid upstream stream"))
                finishChunks(errorCategory: "invalid_upstream_sse")
            }
        } else {
            do {
                let output = try AnthropicMessagesBridge().makeNonStreamingResponse(
                    data: bodyBuffer,
                    mappings: bridgeRequest.toolMappings
                )
                let observation = UsageExtractor.observation(from: output, contentType: "application/json")
                HTTPResponseWriter.send(
                    status: 200,
                    contentType: "application/json; charset=utf-8",
                    body: output,
                    to: connection
                )
                completion(makeMetric(observation: observation, errorCategory: nil))
            } catch {
                HTTPResponseWriter.error(status: 502, message: error.localizedDescription, to: connection)
                completion(makeMetric(observation: ResponseUsageObservation(), errorCategory: "anthropic_bridge_error"))
            }
        }
    }

    private func sendChunk(_ data: Data) {
        guard !data.isEmpty else { return }
        var chunk = Data(String(data.count, radix: 16).utf8)
        chunk.append(Data("\r\n".utf8))
        chunk.append(data)
        chunk.append(Data("\r\n".utf8))
        connection.send(content: chunk, completion: .idempotent)
    }

    private func failureEvent(message: String) -> Data {
        let object: [String: Any] = [
            "type": "response.failed",
            "response": ["error": ["message": message]],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: object) else { return Data() }
        var output = Data("event: response.failed\ndata: ".utf8)
        output.append(payload)
        output.append(Data("\n\n".utf8))
        return output
    }

    private func finishChunks(errorCategory: String?) {
        connection.send(
            content: Data("0\r\n\r\n".utf8),
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [completion] downstreamError in
                self.connection.cancel()
                completion(self.makeMetric(
                    observation: self.converter.observation,
                    errorCategory: errorCategory ?? (downstreamError == nil ? nil : "downstream_error")
                ))
            }
        )
    }

    private func makeMetric(
        observation: ResponseUsageObservation,
        errorCategory: String?
    ) -> RequestMetric {
        let completedAt = Date()
        return RequestMetric(
            startedAt: startedAt,
            completedAt: completedAt,
            providerID: provider.id,
            providerName: provider.profile.displayName,
            endpoint: .responses,
            requestedModel: requestMetadata.model,
            responseModel: observation.model ?? provider.inferenceModel,
            statusCode: statusCode,
            isStreaming: requestMetadata.isStreaming,
            durationMilliseconds: Int(completedAt.timeIntervalSince(startedAt) * 1_000),
            timeToFirstByteMilliseconds: firstByteAt.map { Int($0.timeIntervalSince(startedAt) * 1_000) },
            usage: observation.usage,
            errorCategory: errorCategory
        )
    }
}

private final class AdapterStreamingForwardDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: NWConnection
    private let provider: ActiveProviderSnapshot
    private let requestMetadata: RequestMetadata
    private let startedAt: Date
    private let adapterRequest: AdapterRequest
    private let adapter: any ProviderAdapter
    private let completion: @Sendable (RequestMetric) -> Void
    private let converter: AdapterResponsesStreamConverter
    private var session: URLSession?
    private var statusCode: Int?
    private var contentType: String?
    private var responseStarted = false
    private var firstByteAt: Date?
    private var bodyBuffer = Data()
    private var conversionError: Error?
    #if DEBUG
    private let upstreamRequestBody: Data?
    private var rawUpstream = Data()
    private var convertedOut = Data()
    private static let diagCaptureLimit = 512 * 1024
    #endif

    init(
        connection: NWConnection,
        provider: ActiveProviderSnapshot,
        requestMetadata: RequestMetadata,
        startedAt: Date,
        adapterRequest: AdapterRequest,
        adapter: any ProviderAdapter,
        completion: @escaping @Sendable (RequestMetric) -> Void
    ) {
        self.connection = connection
        self.provider = provider
        self.requestMetadata = requestMetadata
        self.startedAt = startedAt
        self.adapterRequest = adapterRequest
        self.adapter = adapter
        self.completion = completion
        #if DEBUG
        self.upstreamRequestBody = adapterRequest.urlRequest.httpBody
        #endif
        converter = AdapterResponsesStreamConverter(
            decoder: adapter.makeStreamDecoder(mappings: adapterRequest.toolMappings),
            mappings: adapterRequest.toolMappings
        )
    }

    #if DEBUG
    private func appendCapped(_ buffer: inout Data, _ data: Data) {
        let limit = Self.diagCaptureLimit
        guard buffer.count < limit else { return }
        buffer.append(data.prefix(limit - buffer.count))
    }

    /// 诊断落盘：上游请求体 + 上游原始响应 + 转换后输出，用于定位文本泄漏/重复根因。
    private func writeDiagnostic(error: Error?) {
        let dir = AppPaths.logs.appendingPathComponent("diag")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = String(Int(Date().timeIntervalSince1970))
        let path = dir.appendingPathComponent("diag-\(stamp)-\(UUID().uuidString.prefix(8)).log")
        var report = ""
        report += "=== provider: \(provider.profile.displayName) / \(provider.inferenceModel) ===\n"
        report += "=== streaming: \(adapterRequest.clientRequestedStreaming) status: \(statusCode.map(String.init) ?? "?") error: \(error?.localizedDescription ?? "none") ===\n"
        report += "\n########## UPSTREAM REQUEST BODY (sent to model) ##########\n"
        report += prettyJSON(upstreamRequestBody) ?? String(decoding: upstreamRequestBody ?? Data(), as: UTF8.self)
        report += "\n\n########## RAW UPSTREAM RESPONSE (from model, pre-conversion) ##########\n"
        report += String(decoding: rawUpstream, as: UTF8.self)
        report += "\n\n########## CONVERTED OUTPUT (sent to Codex CLI) ##########\n"
        report += String(decoding: convertedOut, as: UTF8.self)
        report += "\n"
        try? report.write(to: path, atomically: true, encoding: .utf8)
        let latest = dir.appendingPathComponent("diag-latest.log")
        try? report.write(to: latest, atomically: true, encoding: .utf8)
        AppLog.info("Diagnostic dump written to \(path.path)")
    }

    private func prettyJSON(_ data: Data?) -> String? {
        guard let data, !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(decoding: pretty, as: UTF8.self)
    }
    #endif

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 3_600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: adapterRequest.urlRequest).resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        statusCode = response.statusCode
        contentType = response.value(forHTTPHeaderField: "Content-Type")
        if (200..<300).contains(response.statusCode), adapterRequest.clientRequestedStreaming {
            let header = [
                "HTTP/1.1 200 OK",
                "Content-Type: text/event-stream; charset=utf-8",
                "Cache-Control: no-cache",
                "Transfer-Encoding: chunked",
                "Connection: close",
                "",
                "",
            ].joined(separator: "\r\n")
            responseStarted = true
            connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
                completionHandler(error == nil ? .allow : .cancel)
            })
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        if firstByteAt == nil { firstByteAt = Date() }
        #if DEBUG
        appendCapped(&rawUpstream, data)
        #endif
        guard (200..<300).contains(statusCode ?? 0), adapterRequest.clientRequestedStreaming else {
            guard bodyBuffer.count + data.count <= HTTPRequestParser.maximumRequestBytes else {
                conversionError = HTTPRequestParserError.requestTooLarge
                dataTask.cancel()
                return
            }
            bodyBuffer.append(data)
            return
        }
        do {
            let converted = try converter.consume(data)
            #if DEBUG
            appendCapped(&convertedOut, converted)
            #endif
            sendChunk(converted)
        } catch {
            conversionError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        #if DEBUG
        defer { writeDiagnostic(error: error) }
        #endif
        defer {
            session.finishTasksAndInvalidate()
            self.session = nil
        }
        if let failure = conversionError ?? error {
            if responseStarted {
                sendChunk(failureEvent(message: failure.localizedDescription))
                finishChunks(errorCategory: "invalid_upstream_stream")
            } else {
                HTTPResponseWriter.error(status: 502, message: failure.localizedDescription, to: connection)
                completion(makeMetric(observation: ResponseUsageObservation(), errorCategory: "network_error"))
            }
            return
        }
        guard (200..<300).contains(statusCode ?? 0) else {
            HTTPResponseWriter.send(
                status: statusCode ?? 502,
                contentType: contentType ?? "application/json; charset=utf-8",
                body: bodyBuffer,
                to: connection
            )
            completion(makeMetric(
                observation: ResponseUsageObservation(),
                errorCategory: "http_\(statusCode ?? 502)"
            ))
            return
        }
        if adapterRequest.clientRequestedStreaming {
            do {
                let converted = try converter.finish()
                #if DEBUG
                appendCapped(&convertedOut, converted)
                #endif
                sendChunk(converted)
                finishChunks(errorCategory: nil)
            } catch {
                sendChunk(failureEvent(message: error.localizedDescription))
                finishChunks(errorCategory: "invalid_upstream_stream")
            }
        } else {
            do {
                let events = try adapter.parseResponse(data: bodyBuffer, mappings: adapterRequest.toolMappings)
                let output = try AdapterResponseBuilder.json(events: events, mappings: adapterRequest.toolMappings)
                #if DEBUG
                appendCapped(&convertedOut, output)
                #endif
                let observation = UsageExtractor.observation(from: output, contentType: "application/json")
                HTTPResponseWriter.send(
                    status: 200,
                    contentType: "application/json; charset=utf-8",
                    body: output,
                    to: connection
                )
                completion(makeMetric(observation: observation, errorCategory: nil))
            } catch {
                HTTPResponseWriter.error(status: 502, message: error.localizedDescription, to: connection)
                completion(makeMetric(observation: ResponseUsageObservation(), errorCategory: "adapter_response_error"))
            }
        }
    }

    private func sendChunk(_ data: Data) {
        guard !data.isEmpty else { return }
        var chunk = Data(String(data.count, radix: 16).utf8)
        chunk.append(Data("\r\n".utf8))
        chunk.append(data)
        chunk.append(Data("\r\n".utf8))
        connection.send(content: chunk, completion: .idempotent)
    }

    private func failureEvent(message: String) -> Data {
        let object: [String: Any] = [
            "type": "response.failed",
            "response": ["status": "failed", "error": ["message": message]],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: object) else { return Data() }
        var output = Data("event: response.failed\ndata: ".utf8)
        output.append(payload)
        output.append(Data("\n\ndata: [DONE]\n\n".utf8))
        return output
    }

    private func finishChunks(errorCategory: String?) {
        connection.send(
            content: Data("0\r\n\r\n".utf8),
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [completion] downstreamError in
                self.connection.cancel()
                completion(self.makeMetric(
                    observation: self.converter.observation,
                    errorCategory: errorCategory ?? (downstreamError == nil ? nil : "downstream_error")
                ))
            }
        )
    }

    private func makeMetric(
        observation: ResponseUsageObservation,
        errorCategory: String?
    ) -> RequestMetric {
        let completedAt = Date()
        return RequestMetric(
            startedAt: startedAt,
            completedAt: completedAt,
            providerID: provider.id,
            providerName: provider.profile.displayName,
            endpoint: .responses,
            requestedModel: requestMetadata.model,
            responseModel: observation.model ?? provider.inferenceModel,
            statusCode: statusCode,
            isStreaming: requestMetadata.isStreaming,
            durationMilliseconds: Int(completedAt.timeIntervalSince(startedAt) * 1_000),
            timeToFirstByteMilliseconds: firstByteAt.map { Int($0.timeIntervalSince(startedAt) * 1_000) },
            usage: observation.usage,
            errorCategory: errorCategory
        )
    }
}

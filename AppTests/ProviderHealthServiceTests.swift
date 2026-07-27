import Foundation
import XCTest
@testable import GPTSwitch

final class ProviderHealthServiceTests: XCTestCase {
    func testModelsCheckFallsBackToV1AfterNotFound() async {
        let recorder = HealthRequestRecorder()
        let service = ProviderHealthService { request in
            await recorder.response(for: request)
        }
        let provider = ProviderProfile(
            configName: "relay",
            displayName: "Relay",
            baseURL: "https://relay.example/api",
            bridgeModel: "gpt-5"
        )

        let result = await service.measureEndpoint(provider: provider, token: "secret")

        XCTAssertEqual(result.state, .healthy)
        XCTAssertEqual(result.statusCode, 200)
        let requests = await recorder.requests
        XCTAssertEqual(requests.map(\.url?.path), ["/api/models", "/api/v1/models"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer secret", "Bearer secret"])
    }

    func testModelDiscoveryFallsBackAndDeduplicatesIDs() async throws {
        let recorder = HealthRequestRecorder()
        let service = ProviderHealthService { request in
            if request.url?.path == "/api/models" {
                return await recorder.response(for: request)
            }
            await recorder.record(request)
            let data = Data(#"{"data":[{"id":"glm-5.2"},{"id":"glm-5.2"},{"id":"deepseek-v4"}]}"#.utf8)
            return (data, HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!)
        }
        let provider = ProviderProfile(
            configName: "relay",
            displayName: "Relay",
            baseURL: "https://relay.example/api",
            bridgeModel: "gpt-5"
        )

        let models = try await service.discoverModels(provider: provider, token: "secret")

        XCTAssertEqual(models, ["glm-5.2", "deepseek-v4"])
        let requests = await recorder.requests
        XCTAssertEqual(requests.map(\.url?.path), ["/api/models", "/api/v1/models"])
    }

    func testResponsesCheckKeepsConfiguredBasePath() async {
        let urls = ProviderEndpointResolver.urls(baseURL: "https://relay.example/api", endpoint: "responses")
        XCTAssertEqual(urls.map(\.absoluteString), ["https://relay.example/api/responses"])
    }

    func testModelCheckUsesStructuredResponsesInput() async throws {
        let recorder = HealthRequestRecorder()
        let service = ProviderHealthService { request in
            await recorder.response(for: request)
        }
        let provider = ProviderProfile(
            configName: "relay",
            displayName: "Relay",
            baseURL: "https://relay.example/api",
            bridgeModel: "gpt-5.5"
        )

        let result = await service.testModel(provider: provider, token: "secret")

        XCTAssertEqual(result.state, .healthy)
        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["role"] as? String, "user")
        let content = try XCTUnwrap(input.first?["content"] as? [[String: String]])
        XCTAssertEqual(content.first?["type"], "input_text")
        XCTAssertEqual(
            content.first?["text"],
            "Use the exec tool once with input pwd. Do not answer with text."
        )
        XCTAssertEqual(object["stream"] as? Bool, false)
        XCTAssertEqual(request.timeoutInterval, 60, accuracy: 0.1)
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "exec")
        XCTAssertNil(object["tool_choice"])
    }

    func testChatGPTModelCheckUsesAccountAuthentication() async throws {
        let recorder = HealthRequestRecorder()
        let service = ProviderHealthService { request in
            await recorder.response(for: request)
        }
        let provider = ProviderProfile(
            configName: "chatgpt",
            displayName: "ChatGPT",
            baseURL: ChatGPTProviderDefaults.baseURL,
            bridgeModel: "gpt-5",
            credentialMode: .chatGPTAccount
        )

        let result = await service.testModel(
            provider: provider,
            token: "access-token",
            chatGPTAccountID: "account-test"
        )

        XCTAssertEqual(result.state, .healthy)
        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "\(ChatGPTProviderDefaults.baseURL)/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account-test")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
    }

    func testChatGPTEndpointCheckUsesResponsesInsteadOfModels() async throws {
        let recorder = HealthRequestRecorder()
        let service = ProviderHealthService { request in
            await recorder.response(for: request)
        }
        let provider = ChatGPTProviderDefaults.profile(
            id: UUID(),
            modelID: "gpt-current",
            sortOrder: 0
        )

        let result = await service.measureEndpoint(
            provider: provider,
            token: "access-token",
            chatGPTAccountID: "account-test"
        )

        XCTAssertEqual(result.state, .healthy)
        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "\(ChatGPTProviderDefaults.baseURL)/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account-test")
    }

    func testChatGPTModelDiscoveryUsesLocalCatalogWithoutNetwork() async throws {
        let recorder = HealthRequestRecorder()
        let service = ProviderHealthService { request in
            await recorder.response(for: request)
        }
        let provider = ChatGPTProviderDefaults.profile(
            id: UUID(),
            modelID: "gpt-current",
            sortOrder: 0
        )

        let models = try await service.discoverModels(provider: provider, token: nil)

        XCTAssertEqual(models, ["gpt-current"])
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testModelsCheckDoesNotDuplicateExistingV1Path() async {
        let urls = ProviderEndpointResolver.urls(baseURL: "https://relay.example/api/v1", endpoint: "models")
        XCTAssertEqual(urls.map(\.absoluteString), ["https://relay.example/api/v1/models"])
    }

    func testChatModelCheckUsesChatCompletionsAndDisablesThinking() async throws {
        let recorder = HealthRequestRecorder()
        let service = ProviderHealthService { request in
            await recorder.response(for: request)
        }
        let provider = ProviderProfile(
            configName: "glm",
            displayName: "GLM",
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            bridgeModel: "",
            wireProtocol: .chatCompletions,
            chatDialect: .glm,
            inferenceModel: "glm-5.2"
        )

        let result = await service.testModel(provider: provider, token: "secret")

        XCTAssertEqual(result.state, .healthy)
        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/paas/v4/chat/completions")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "glm-5.2")
        XCTAssertEqual((object["thinking"] as? [String: String])?["type"], "disabled")
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        let function = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "exec")
        XCTAssertNil(object["tool_choice"])
    }

    func testAnthropicModelCheckRequiresNativeToolUse() async throws {
        let recorder = HealthRequestRecorder()
        let service = ProviderHealthService { request in
            await recorder.response(for: request)
        }
        let provider = ProviderProfile(
            configName: "claude",
            displayName: "Claude",
            baseURL: "https://relay.example/api/v1",
            bridgeModel: "",
            wireProtocol: .anthropicMessages,
            inferenceModel: "claude-opus-4-8"
        )

        let result = await service.testModel(provider: provider, token: "secret")

        XCTAssertEqual(result.state, .healthy)
        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "claude-opus-4-8")
        XCTAssertEqual(object["stream"] as? Bool, false)
        XCTAssertEqual(object["max_tokens"] as? Int, 1_025)
        XCTAssertEqual(
            object["system"] as? String,
            "Use tools only through native tool_use blocks. Never write tool calls as XML or JSON text."
        )
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "exec")
        let toolChoice = try XCTUnwrap(object["tool_choice"] as? [String: String])
        XCTAssertEqual(toolChoice["type"], "tool")
        XCTAssertEqual(toolChoice["name"], "exec")
    }

    func testModelCheckRejectsTextualPseudoToolCall() async {
        let service = ProviderHealthService { request in
            let data = Data(#"{"content":[{"type":"text","text":"<invoke name=\"functions.exec\">"}]}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (data, response)
        }
        let provider = ProviderProfile(
            configName: "claude",
            displayName: "Claude",
            baseURL: "https://relay.example/api/v1",
            bridgeModel: "",
            wireProtocol: .anthropicMessages,
            inferenceModel: "claude-opus-4-8"
        )

        let result = await service.testModel(provider: provider, token: nil)

        XCTAssertEqual(result.state, .unavailable)
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.message, "模型不支持原生结构化工具调用，无法用于 Codex")
    }

    func testModelCheckReportsProbeTimeout() async {
        let service = ProviderHealthService { _ in
            throw URLError(.timedOut)
        }
        let provider = ProviderProfile(
            configName: "relay",
            displayName: "Relay",
            baseURL: "https://relay.example/api",
            bridgeModel: "gpt-5.5"
        )

        let result = await service.testModel(provider: provider, token: "secret")

        XCTAssertEqual(result.state, .unavailable)
        XCTAssertEqual(result.message, "检测超时（60 秒）")
    }

    func testModelCheckIncludesUpstreamErrorMessage() async {
        let service = ProviderHealthService { request in
            let data = Data(#"{"error":{"type":"api_error","message":"model temporarily unavailable"}}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (data, response)
        }
        let provider = ProviderProfile(
            configName: "claude",
            displayName: "Claude",
            baseURL: "https://relay.example/api/v1",
            bridgeModel: "",
            wireProtocol: .anthropicMessages,
            inferenceModel: "claude-opus-4-8"
        )

        let result = await service.testModel(provider: provider, token: "secret")

        XCTAssertEqual(result.state, .unavailable)
        XCTAssertEqual(result.statusCode, 500)
        XCTAssertEqual(result.message, "HTTP 500：model temporarily unavailable")
    }
}

private actor HealthRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func response(for request: URLRequest) -> (Data, URLResponse) {
        requests.append(request)
        let statusCode = request.url?.path == "/api/models" ? 404 : 200
        let data: Data
        switch request.url?.lastPathComponent {
        case "responses":
            data = Data(#"{"output":[{"type":"function_call","name":"exec","arguments":"{\"input\":\"pwd\"}"}]}"#.utf8)
        case "chat", "completions":
            data = Data(#"{"choices":[{"message":{"tool_calls":[{"type":"function","function":{"name":"exec","arguments":"{\"input\":\"pwd\"}"}}]}}]}"#.utf8)
        case "messages":
            data = Data(#"{"content":[{"type":"tool_use","id":"toolu-probe","name":"exec","input":{"input":"pwd"}}]}"#.utf8)
        default:
            data = Data()
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (data, response)
    }

    func record(_ request: URLRequest) {
        requests.append(request)
    }
}

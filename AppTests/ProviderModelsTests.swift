import Foundation
import XCTest
@testable import GPTSwitch

final class ProviderModelsTests: XCTestCase {
    @MainActor
    func testMainNavigationCoordinatesProviderEditingAndUsageFiltering() {
        let navigation = MainNavigation()
        let providerID = UUID()

        navigation.editProvider(providerID)
        XCTAssertEqual(navigation.section, .providers)
        XCTAssertEqual(navigation.editingProviderID, providerID)

        navigation.showUsage(for: providerID)
        XCTAssertEqual(navigation.section, .usage)
        XCTAssertNil(navigation.editingProviderID)
        XCTAssertEqual(navigation.usageProviderFilter, providerID)

        navigation.show(.settings)
        XCTAssertEqual(navigation.section, .settings)
        XCTAssertNil(navigation.usageProviderFilter)
    }

    func testURLValidationNormalizesAndRejectsProxyLoop() throws {
        let normalized = try ProviderURLValidator.normalize(" HTTPS://relay.example/v1/ ", proxyPort: 17891)
        XCTAssertEqual(normalized, "https://relay.example/v1")
        XCTAssertThrowsError(try ProviderURLValidator.normalize("http://127.0.0.1:17891/v1", proxyPort: 17891))
        XCTAssertThrowsError(try ProviderURLValidator.normalize("https://user:pass@example.com/v1", proxyPort: 17891))
        XCTAssertNoThrow(try ProviderURLValidator.normalize("http://127.0.0.1:8080/v1", proxyPort: 17891))
    }

    func testRouterUsesStableRequestSnapshot() {
        let first = snapshot(name: "First", token: "first-token")
        let second = snapshot(name: "Second", token: "second-token")
        let router = ActiveProviderRouter(snapshot: first)

        let requestSnapshot = router.snapshot()
        router.update(second)

        XCTAssertEqual(requestSnapshot.profile.displayName, "First")
        XCTAssertEqual(router.snapshot().profile.displayName, "Second")
    }

    func testRouterAllowsDefaultSnapshotInSnapshotList() {
        let defaultProvider = snapshot(name: "Default", token: "current-token")
        let staleDefault = ActiveProviderSnapshot(
            profile: defaultProvider.profile,
            bearerToken: "stale-token"
        )
        let other = snapshot(name: "Other", token: "other-token")
        let router = ActiveProviderRouter(
            snapshot: defaultProvider,
            snapshots: [staleDefault, other]
        )

        XCTAssertEqual(router.allSnapshots().count, 2)
        XCTAssertEqual(router.snapshot().bearerToken, "current-token")

        router.update(default: defaultProvider, snapshots: [other, staleDefault])

        XCTAssertEqual(router.allSnapshots().count, 2)
        XCTAssertEqual(router.snapshot().bearerToken, "current-token")
    }

    func testRouterSelectsProviderAndRestoresNativeModelID() throws {
        let defaultProvider = snapshot(
            configName: "openai",
            name: "OpenAI",
            model: "gpt-5.5",
            token: "openai-token"
        )
        let anthropic = snapshot(
            configName: "anthropic",
            name: "Anthropic",
            model: "anthropic/claude-sonnet-4-6",
            token: "anthropic-token"
        )
        let router = ActiveProviderRouter(
            snapshot: defaultProvider,
            snapshots: [anthropic],
            allowsCrossProviderRouting: true
        )

        let routed = try router.route(model: "anthropic/anthropic-claude-sonnet-4-6")

        XCTAssertEqual(routed.profile.configName, "anthropic")
        XCTAssertEqual(routed.inferenceModel, "anthropic/claude-sonnet-4-6")
        XCTAssertEqual(
            try router.route(model: "anthropic/anthropic/claude-sonnet-4-6").inferenceModel,
            "anthropic/claude-sonnet-4-6"
        )
        XCTAssertEqual(try router.route(model: "gpt-5.5").profile.configName, "openai")
    }

    func testRouterRestrictsModelsToCurrentProviderByDefault() throws {
        let current = snapshot(
            configName: "openai",
            name: "OpenAI",
            model: "gpt-5.5",
            token: "openai-token"
        )
        let other = snapshot(
            configName: "anthropic",
            name: "Anthropic",
            model: "claude-sonnet-4-6",
            token: "anthropic-token"
        )
        let router = ActiveProviderRouter(snapshot: current, snapshots: [other])

        XCTAssertEqual(try router.route(model: "openai/gpt-5.5").profile.configName, "openai")
        XCTAssertThrowsError(try router.route(model: "anthropic/claude-sonnet-4-6")) { error in
            XCTAssertEqual(
                error as? ProviderRoutingError,
                .modelUnavailableForCurrentProvider("anthropic/claude-sonnet-4-6", "OpenAI")
            )
        }

        router.setAllowsCrossProviderRouting(true)
        XCTAssertEqual(
            try router.route(model: "anthropic/claude-sonnet-4-6").profile.configName,
            "anthropic"
        )
    }

    func testRouterRequiresPrefixForAmbiguousBareModel() {
        let first = snapshot(configName: "first", name: "First", model: "shared", token: "one")
        let second = snapshot(configName: "second", name: "Second", model: "shared", token: "two")
        let defaultProvider = snapshot(configName: "default", name: "Default", model: "other", token: "default")
        let router = ActiveProviderRouter(
            snapshot: defaultProvider,
            snapshots: [first, second],
            allowsCrossProviderRouting: true
        )

        XCTAssertThrowsError(try router.route(model: "shared")) { error in
            XCTAssertEqual(error as? ProviderRoutingError, .ambiguousModel("shared"))
        }
        XCTAssertEqual(try? router.route(model: "second/shared").profile.configName, "second")
    }

    func testChatProviderRequiresInferenceModelInsteadOfBridgeModel() throws {
        let valid = ProviderProfile(
            configName: "chat",
            displayName: "Chat",
            baseURL: "https://chat.example/v1",
            bridgeModel: "",
            wireProtocol: .chatCompletions,
            inferenceModel: "relay-opus"
        )
        XCTAssertNoThrow(try valid.validated(proxyPort: 17891))

        var invalid = valid
        invalid.inferenceModel = ""
        XCTAssertThrowsError(try invalid.validated(proxyPort: 17891))
    }

    func testAuthorizerReplacesBearerTokenWithoutPersistingItInProfile() {
        let provider = snapshot(name: "Relay", token: "new-secret")
        var request = URLRequest(url: URL(string: "https://relay.example/v1/responses")!)
        request.setValue("Bearer old-secret", forHTTPHeaderField: "Authorization")

        ProviderRequestAuthorizer.apply(provider, to: &request)

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-secret")
        XCTAssertFalse(provider.profile.baseURL.contains("new-secret"))
    }

    func testChatGPTAuthorizerPreservesIncomingTokenAndAddsAccountID() {
        let providerID = UUID()
        let profile = ProviderProfile(
            id: providerID,
            configName: "chatgpt",
            displayName: "ChatGPT",
            baseURL: ChatGPTProviderDefaults.baseURL,
            bridgeModel: "gpt-5",
            credentialMode: .chatGPTAccount
        )
        let provider = ActiveProviderSnapshot(
            profile: profile,
            bearerToken: "fallback-token",
            chatGPTAccountID: "account-test"
        )
        var request = URLRequest(url: URL(string: ChatGPTProviderDefaults.baseURL)!)
        request.setValue("Bearer refreshed-token", forHTTPHeaderField: "Authorization")

        ProviderRequestAuthorizer.apply(provider, to: &request)

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer refreshed-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account-test")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
    }

    func testChatGPTProviderRequiresOfficialResponsesEndpoint() throws {
        let providerID = UUID()
        let valid = ProviderProfile(
            id: providerID,
            configName: "chatgpt",
            displayName: "ChatGPT",
            baseURL: ChatGPTProviderDefaults.baseURL,
            bridgeModel: "gpt-5",
            credentialMode: .chatGPTAccount
        )
        XCTAssertNoThrow(try valid.validated(proxyPort: 17_891))

        var invalid = valid
        invalid.baseURL = "https://api.openai.com/v1"
        XCTAssertThrowsError(try invalid.validated(proxyPort: 17_891)) { error in
            XCTAssertEqual(error as? ProviderValidationError, .invalidChatGPTProvider)
        }
    }

    func testChatGPTProviderTemplateUsesCurrentModelWithoutAPIKey() {
        let providerID = UUID()
        let provider = ChatGPTProviderDefaults.profile(
            id: providerID,
            modelID: "current-codex-model",
            sortOrder: 3
        )

        XCTAssertEqual(provider.configName, "chatgpt")
        XCTAssertEqual(provider.baseURL, "https://chatgpt.com/backend-api/codex")
        XCTAssertEqual(provider.wireProtocol, .responses)
        XCTAssertEqual(provider.credentialMode, .chatGPTAccount)
        XCTAssertEqual(provider.bridgeModel, "current-codex-model")
        XCTAssertEqual(provider.models.first?.modelID, "current-codex-model")
        XCTAssertEqual(provider.models.first?.providerID, providerID)
        XCTAssertEqual(provider.sortOrder, 3)
    }

    private func snapshot(name: String, token: String) -> ActiveProviderSnapshot {
        ActiveProviderSnapshot(
            profile: ProviderProfile(
                configName: name.lowercased(),
                displayName: name,
                baseURL: "https://\(name.lowercased()).example/v1",
                bridgeModel: "gpt-5"
            ),
            bearerToken: token
        )
    }

    private func snapshot(
        configName: String,
        name: String,
        model: String,
        token: String
    ) -> ActiveProviderSnapshot {
        let providerID = UUID()
        return ActiveProviderSnapshot(
            profile: ProviderProfile(
                id: providerID,
                configName: configName,
                displayName: name,
                baseURL: "https://relay.example/v1",
                bridgeModel: model,
                inferenceModel: model,
                models: [ProviderModelRoute(
                    providerID: providerID,
                    modelID: model,
                    displayName: model
                )]
            ),
            bearerToken: token
        )
    }
}

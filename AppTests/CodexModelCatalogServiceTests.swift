import Foundation
import XCTest
@testable import GPTSwitch

final class CodexModelCatalogServiceTests: XCTestCase {
    func testSyncBuildsRoutedCatalogAndRestoreReturnsOriginalConfig() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        let catalogURL = directory.appendingPathComponent("gptswitch-catalog.json")
        let cacheURL = directory.appendingPathComponent("models_cache.json")
        let stateURL = directory.appendingPathComponent("catalog-state.json")
        let backupURL = directory.appendingPathComponent("native-backup.json")
        let originalConfig = """
        model = "gpt-5.5"
        model_provider = "relay"

        [model_providers.relay]
        base_url = "http://127.0.0.1:17891/v1"
        """
        try originalConfig.write(to: configURL, atomically: true, encoding: .utf8)
        try writeJSON([
            "fetched_at": "2026-07-22T00:00:00Z",
            "client_version": "0.144.4",
            "models": [[
                "slug": "gpt-5.5",
                "display_name": "GPT-5.5",
                "description": "Native",
                "base_instructions": "Be helpful",
                "default_reasoning_level": "medium",
                "supported_reasoning_levels": [["effort": "medium", "description": "Medium"]],
                "shell_type": "shell_command",
                "supported_in_api": true,
                "visibility": "list",
                "service_tiers": [["id": "priority"]],
            ]],
        ], to: cacheURL)
        let providerID = UUID()
        let provider = ProviderProfile(
            id: providerID,
            configName: "anthropic",
            displayName: "Anthropic",
            baseURL: "https://api.anthropic.com",
            bridgeModel: "",
            wireProtocol: .anthropicMessages,
            inferenceModel: "anthropic/claude-sonnet-4-6",
            models: [ProviderModelRoute(
                providerID: providerID,
                modelID: "anthropic/claude-sonnet-4-6",
                displayName: "Claude Sonnet",
                reasoningEfforts: ["low", "high"],
                defaultReasoningEffort: "high",
                inputModalities: ["text", "image"]
            )]
        )
        let service = CodexModelCatalogService()

        let result = try service.sync(
            provider: provider,
            configURL: configURL,
            catalogURL: catalogURL,
            cacheURL: cacheURL,
            stateURL: stateURL,
            nativeBackupURL: backupURL
        )

        XCTAssertEqual(result.routedModelCount, 1)
        let config = try String(contentsOf: configURL)
        XCTAssertTrue(config.contains("model_catalog_json = \"\(catalogURL.path)\""))
        XCTAssertTrue(config.contains("model = \"anthropic/anthropic-claude-sonnet-4-6\""))
        XCTAssertLessThan(
            try XCTUnwrap(config.range(of: "model_catalog_json")?.lowerBound),
            try XCTUnwrap(config.range(of: "[model_providers.relay]")?.lowerBound)
        )
        let catalog = try readJSON(catalogURL)
        let models = try XCTUnwrap(catalog["models"] as? [[String: Any]])
        XCTAssertEqual(models.count, 1)
        let routed = try XCTUnwrap(models.first { $0["slug"] as? String == "anthropic/anthropic-claude-sonnet-4-6" })
        XCTAssertEqual(routed["display_name"] as? String, "Claude Sonnet")
        XCTAssertNil(routed["service_tiers"])
        XCTAssertEqual(routed["input_modalities"] as? [String], ["text", "image"])

        let secondSync = try service.sync(
            provider: provider,
            configURL: configURL,
            catalogURL: catalogURL,
            cacheURL: cacheURL,
            stateURL: stateURL,
            nativeBackupURL: backupURL
        )
        XCTAssertEqual(secondSync.routedModelCount, 1)
        let codexResponse = try JSONSerialization.jsonObject(with: service.modelsResponse(
            provider: provider,
            catalogURL: catalogURL,
            codexShape: true
        )) as? [String: Any]
        XCTAssertEqual((codexResponse?["models"] as? [[String: Any]])?.count, 1)
        let openAIResponse = try JSONSerialization.jsonObject(with: service.modelsResponse(
            provider: provider,
            catalogURL: catalogURL,
            codexShape: false
        )) as? [String: Any]
        XCTAssertEqual(
            ((openAIResponse?["data"] as? [[String: Any]])?.first)?["id"] as? String,
            "anthropic/anthropic-claude-sonnet-4-6"
        )

        let nextProviderID = UUID()
        let nextProvider = ProviderProfile(
            id: nextProviderID,
            configName: "openai",
            displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            bridgeModel: "gpt-5.5",
            models: [ProviderModelRoute(
                providerID: nextProviderID,
                modelID: "gpt-5.5",
                displayName: "GPT-5.5"
            )]
        )
        let switched = try service.sync(
            provider: nextProvider,
            configURL: configURL,
            catalogURL: catalogURL,
            cacheURL: cacheURL,
            stateURL: stateURL,
            nativeBackupURL: backupURL
        )
        XCTAssertEqual(switched.routedModelCount, 1)
        XCTAssertTrue(try String(contentsOf: configURL).contains("model = \"openai/gpt-5.5\""))
        let switchedCatalog = try readJSON(catalogURL)
        let switchedModels = try XCTUnwrap(switchedCatalog["models"] as? [[String: Any]])
        XCTAssertEqual(switchedModels.count, 1)
        XCTAssertNotNil(switchedModels.first { $0["slug"] as? String == "openai/gpt-5.5" })
        XCTAssertNil(switchedModels.first {
            ($0["slug"] as? String)?.hasPrefix("anthropic/") == true
        })
        let switchedResponse = try JSONSerialization.jsonObject(with: service.modelsResponse(
            provider: nextProvider,
            catalogURL: catalogURL,
            codexShape: true
        )) as? [String: Any]
        XCTAssertEqual(
            ((switchedResponse?["models"] as? [[String: Any]])?.first)?["slug"] as? String,
            "openai/gpt-5.5"
        )

        try service.restore(
            configURL: configURL,
            catalogURL: catalogURL,
            cacheURL: cacheURL,
            stateURL: stateURL,
            nativeBackupURL: backupURL
        )
        XCTAssertEqual(try String(contentsOf: configURL), originalConfig)
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL.path))
    }

    func testSyncUpgradesLegacyStateAndRestoresOriginalModel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        let catalogURL = directory.appendingPathComponent("gptswitch-catalog.json")
        let cacheURL = directory.appendingPathComponent("models_cache.json")
        let stateURL = directory.appendingPathComponent("catalog-state.json")
        let backupURL = directory.appendingPathComponent("native-backup.json")
        let originalConfig = "model = \"gpt-native\"\nmodel_provider = \"relay\"\n"
        try (originalConfig + "model_catalog_json = \"\(catalogURL.path)\"\n")
            .write(to: configURL, atomically: true, encoding: .utf8)
        let nativeCatalog: [String: Any] = [
            "models": [[
                "slug": "gpt-native",
                "display_name": "GPT Native",
                "base_instructions": "Be helpful",
            ]],
        ]
        try writeJSON(nativeCatalog, to: cacheURL)
        try writeJSON(nativeCatalog, to: backupURL)
        try writeJSON(["originalCatalogPath": NSNull()], to: stateURL)
        let providerID = UUID()
        let provider = ProviderProfile(
            id: providerID,
            configName: "openai",
            displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            bridgeModel: "gpt-5.5",
            models: [ProviderModelRoute(
                providerID: providerID,
                modelID: "gpt-5.5",
                displayName: "GPT-5.5"
            )]
        )
        let service = CodexModelCatalogService()

        _ = try service.sync(
            provider: provider,
            configURL: configURL,
            catalogURL: catalogURL,
            cacheURL: cacheURL,
            stateURL: stateURL,
            nativeBackupURL: backupURL
        )
        XCTAssertTrue(try String(contentsOf: configURL).contains("model = \"openai/gpt-5.5\""))

        try service.restore(
            configURL: configURL,
            catalogURL: catalogURL,
            cacheURL: cacheURL,
            stateURL: stateURL,
            nativeBackupURL: backupURL
        )
        XCTAssertEqual(try String(contentsOf: configURL), originalConfig)
    }

    func testSyncBootstrapsWhenNativeCatalogIsMissing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        let catalogURL = directory.appendingPathComponent("gptswitch-catalog.json")
        let cacheURL = directory.appendingPathComponent("models_cache.json")
        let stateURL = directory.appendingPathComponent("catalog-state.json")
        let backupURL = directory.appendingPathComponent("native-backup.json")
        let missingNativeCatalogURL = directory.appendingPathComponent("missing-native-catalog.json")
        try "model = \"provider-model\"\nmodel_catalog_json = \"\(missingNativeCatalogURL.path)\"\n"
            .write(to: configURL, atomically: true, encoding: .utf8)
        let providerID = UUID()
        let provider = ProviderProfile(
            id: providerID,
            configName: "provider",
            displayName: "Provider",
            baseURL: "https://example.com/v1",
            bridgeModel: "provider-model",
            models: [ProviderModelRoute(
                providerID: providerID,
                modelID: "provider-model",
                displayName: "Provider Model"
            )]
        )

        let result = try CodexModelCatalogService().sync(
            provider: provider,
            configURL: configURL,
            catalogURL: catalogURL,
            cacheURL: cacheURL,
            stateURL: stateURL,
            nativeBackupURL: backupURL
        )

        XCTAssertEqual(result.routedModelCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
        let catalog = try readJSON(catalogURL)
        let model = try XCTUnwrap((catalog["models"] as? [[String: Any]])?.first)
        XCTAssertEqual(model["slug"] as? String, "provider/provider-model")
        XCTAssertEqual(model["base_instructions"] as? String, "Be helpful and follow the user's instructions.")
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

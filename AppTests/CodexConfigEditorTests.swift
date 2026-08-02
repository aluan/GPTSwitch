import Foundation
import XCTest
@testable import GPTSwitch

final class CodexConfigEditorTests: XCTestCase {
    func testEnableAndRestoreOnlyChangesProviderBaseURL() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        let original = """
        model = "gpt-5.5"
        model_provider = "relay"

        [model_providers.relay]
        name = "Relay"
        base_url = "https://relay.example/api"
        experimental_bearer_token = "secret"

        [features]
        image_generation = true
        """
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        let editor = CodexConfigEditor()
        let configuration = try editor.enable(at: configURL, port: 17891, bridgeModel: nil)

        XCTAssertEqual(configuration.bridgeModel, "gpt-5.5")
        XCTAssertEqual(configuration.localBaseURL, "http://127.0.0.1:17891/api")
        let enabled = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(enabled.contains("base_url = \"http://127.0.0.1:17891/api\""))
        XCTAssertTrue(enabled.contains("experimental_bearer_token = \"secret\""))

        try editor.restore(configuration)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), original)
    }

    func testRestoreRefusesUnexpectedConfigurationChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        try "model = \"gpt-5\"\nmodel_provider = \"relay\"\n[model_providers.relay]\nbase_url = \"https://relay.example/api\""
            .write(to: configURL, atomically: true, encoding: .utf8)
        let editor = CodexConfigEditor()
        let configuration = try editor.enable(at: configURL, port: 17891, bridgeModel: nil)
        try "model = \"gpt-5\"\nmodel_provider = \"relay\"\n[model_providers.relay]\nbase_url = \"https://other.example/api\""
            .write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try editor.restore(configuration))
    }

    func testActivateRepairsUpstreamURLAndRestoreIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        let original = "model = \"gpt-5\"\nmodel_provider = \"relay\"\n[model_providers.relay]\nbase_url = \"https://relay.example/api\""
        try original.write(to: configURL, atomically: true, encoding: .utf8)
        let configuration = ProxyConfiguration(
            configPath: configURL.path,
            providerName: "relay",
            bridgeModel: "gpt-5",
            upstreamBaseURL: "https://relay.example/api",
            localBaseURL: "http://127.0.0.1:17891/api",
            port: 17891,
            backupPath: nil
        )

        try CodexConfigEditor().activate(configuration)
        XCTAssertTrue(try String(contentsOf: configURL).contains(
            "base_url = \"http://127.0.0.1:17891/api\""
        ))

        try CodexConfigEditor().restore(configuration)
        try CodexConfigEditor().restore(configuration)
        XCTAssertEqual(try String(contentsOf: configURL), original)
    }

    func testAdoptLoopbackRecoversConfigurationWithoutSavedState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        let original = "model = \"gpt-5\"\nmodel_provider = \"relay\"\n[model_providers.relay]\nbase_url = \"http://127.0.0.1:17891/api\""
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        let configuration = try CodexConfigEditor().adoptLoopback(
            at: configURL,
            port: 17891,
            bridgeModel: "gpt-5.5",
            upstreamBaseURL: "https://relay.example/api"
        )

        XCTAssertEqual(configuration.upstreamBaseURL, "https://relay.example/api")
        XCTAssertEqual(configuration.localBaseURL, "http://127.0.0.1:17891/api")
        XCTAssertNil(configuration.backupPath)
        try CodexConfigEditor().restore(configuration)
        XCTAssertEqual(
            try String(contentsOf: configURL),
            "model = \"gpt-5\"\nmodel_provider = \"relay\"\n[model_providers.relay]\nbase_url = \"https://relay.example/api\""
        )
    }

    func testInspectsAllProviderSectionsAndRestoresCurrentUpstream() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        let config = """
        model = "gpt-5"
        model_provider = "relay"

        [model_providers.relay]
        name = "Relay One"
        base_url = "http://127.0.0.1:17891/api"
        env_key = "RELAY_KEY"

        [model_providers."relay-two"]
        name = "Relay Two"
        base_url = "https://two.example/v1"
        experimental_bearer_token = "secret-two"
        """
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        let installed = ProxyConfiguration(
            configPath: configURL.path,
            providerName: "relay",
            bridgeModel: "gpt-5.5",
            upstreamBaseURL: "https://one.example/api",
            localBaseURL: "http://127.0.0.1:17891/api",
            port: 17891,
            backupPath: nil
        )

        let providers = try CodexConfigEditor().inspectProviders(
            at: configURL,
            originalConfiguration: installed
        )

        XCTAssertEqual(providers.count, 2)
        XCTAssertEqual(providers[0].displayName, "Relay One")
        XCTAssertEqual(providers[0].baseURL, "https://one.example/api")
        XCTAssertEqual(providers[0].environmentKey, "RELAY_KEY")
        XCTAssertTrue(providers[0].isCurrent)
        XCTAssertEqual(providers[1].configName, "relay-two")
        XCTAssertEqual(providers[1].bearerToken, "secret-two")
    }

    // MARK: - 裸 ChatGPT 账号流（无 model_provider / 无 provider 段）

    private func writeBareChatGPTConfig(_ configURL: URL) throws -> String {
        let original = """
        model = "chatgpt/gpt-5"
        model_reasoning_effort = "high"

        [marketplaces.openai-bundled]
        last_updated = "2026-08-01T13:18:15Z"
        source_type = "local"
        source = "/Users/luanqq/.codex/.tmp/bundled-marketplaces/openai-bundled"
        """
        try original.write(to: configURL, atomically: true, encoding: .utf8)
        return original
    }

    func testInspectBareChatGPTFlowSynthesizesDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        try writeBareChatGPTConfig(configURL)

        let inspection = try CodexConfigEditor().inspect(at: configURL)
        XCTAssertEqual(inspection.providerName, "chatgpt")
        XCTAssertEqual(inspection.baseURL, "https://chatgpt.com/backend-api/codex")
        XCTAssertEqual(inspection.model, "chatgpt/gpt-5")
    }

    func testEnableOnBareChatGPTFlowInjectsSection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        try writeBareChatGPTConfig(configURL)

        let configuration = try CodexConfigEditor().enable(at: configURL, port: 17891, bridgeModel: nil)
        XCTAssertTrue(configuration.providerSectionInjected)
        XCTAssertEqual(configuration.providerName, "chatgpt")
        XCTAssertEqual(configuration.upstreamBaseURL, "https://chatgpt.com/backend-api/codex")
        XCTAssertEqual(configuration.localBaseURL, "http://127.0.0.1:17891/backend-api/codex")

        let enabled = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(enabled.contains("[model_providers.chatgpt]"))
        XCTAssertTrue(enabled.contains("base_url = \"http://127.0.0.1:17891/backend-api/codex\""))
        // model_provider 必须出现在首个 [ 行之前。
        let firstSection = enabled.firstIndex(of: "[")!
        let topRegion = String(enabled[..<firstSection])
        XCTAssertTrue(topRegion.contains("model_provider = \"chatgpt\""))
        // [marketplaces] 段保留。
        XCTAssertTrue(enabled.contains("[marketplaces.openai-bundled]"))
    }

    func testRestoreOnInjectedSectionReturnsToBareFlow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        let original = try writeBareChatGPTConfig(configURL)

        let editor = CodexConfigEditor()
        let configuration = try editor.enable(at: configURL, port: 17891, bridgeModel: nil)
        try editor.restore(configuration)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), original)
    }

    func testRestoreIsIdempotentOnBareFlow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        let original = try writeBareChatGPTConfig(configURL)

        let editor = CodexConfigEditor()
        let configuration = try editor.enable(at: configURL, port: 17891, bridgeModel: nil)
        try editor.restore(configuration)
        try editor.restore(configuration)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), original)
    }

    func testActivateReinjectsAfterManualBareRestore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        let original = try writeBareChatGPTConfig(configURL)

        let editor = CodexConfigEditor()
        let configuration = try editor.enable(at: configURL, port: 17891, bridgeModel: nil)
        // 用户手动还原成裸流。
        try original.write(to: configURL, atomically: true, encoding: .utf8)
        try editor.activate(configuration)
        let content = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(content.contains("[model_providers.chatgpt]"))
        XCTAssertTrue(content.contains("base_url = \"http://127.0.0.1:17891/backend-api/codex\""))
    }

    func testActivateNoopWhenSectionPresentAndLoopback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        try writeBareChatGPTConfig(configURL)

        let editor = CodexConfigEditor()
        let configuration = try editor.enable(at: configURL, port: 17891, bridgeModel: nil)
        let afterEnable = try String(contentsOf: configURL, encoding: .utf8)
        try editor.activate(configuration)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), afterEnable)
    }

    func testRestoreRefusesUnexpectedChangeOnInjectedSection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        try writeBareChatGPTConfig(configURL)

        let editor = CodexConfigEditor()
        let configuration = try editor.enable(at: configURL, port: 17891, bridgeModel: nil)
        // 把注入段的 base_url 手改成第三值（非 loopback、非上游）。
        let tampered = try String(contentsOf: configURL, encoding: .utf8)
            .replacingOccurrences(
                of: "http://127.0.0.1:17891/backend-api/codex",
                with: "https://evil.example/api"
            )
        try tampered.write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try editor.restore(configuration))
    }

    func testParseStillThrowsForStaleModelProviderWithoutSection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        // model_provider 存在但无对应段 → 不触发裸流合成，应抛 missingProvider。
        try "model = \"gpt-5\"\nmodel_provider = \"aigocode\"".write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CodexConfigEditor().inspect(at: configURL)) { error in
            guard case ConfigEditorError.missingProvider = error else {
                XCTFail("expected missingProvider, got \(error)")
                return
            }
        }
    }

    func testOldSavedConfigurationWithoutInjectedFlagRestoresViaRewrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        // 用户自建 chatgpt 段（loopback）+ 旧存档无 injected 标记。
        try "model = \"chatgpt/gpt-5\"\nmodel_provider = \"chatgpt\"\n[model_providers.chatgpt]\nbase_url = \"http://127.0.0.1:17891/backend-api/codex\""
            .write(to: configURL, atomically: true, encoding: .utf8)
        let configuration = ProxyConfiguration(
            configPath: configURL.path,
            providerName: "chatgpt",
            bridgeModel: "gpt-5",
            upstreamBaseURL: "https://chatgpt.com/backend-api/codex",
            localBaseURL: "http://127.0.0.1:17891/backend-api/codex",
            port: 17891,
            backupPath: nil,
            providerSectionInjected: false
        )
        try CodexConfigEditor().restore(configuration)
        let restored = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(restored.contains("base_url = \"https://chatgpt.com/backend-api/codex\""))
        XCTAssertTrue(restored.contains("[model_providers.chatgpt]")) // 段保留（option a）
    }
}

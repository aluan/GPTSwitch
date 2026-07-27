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
}

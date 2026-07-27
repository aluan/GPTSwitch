import Foundation
import XCTest
@testable import GPTSwitch

final class ProviderMigrationTests: XCTestCase {
    func testImportsAllProvidersAndMovesCredentialsToCredentialStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        let authURL = directory.appendingPathComponent("auth.json")
        let databaseURL = directory.appendingPathComponent("gptswitch.sqlite3")
        let config = """
        model = "gpt-5"
        model_provider = "one"

        [model_providers.one]
        name = "One"
        base_url = "http://127.0.0.1:17891/v1"

        [model_providers.two]
        name = "Two"
        base_url = "https://two.example/v1"
        experimental_bearer_token = "two-secret"
        """
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        try Data(#"{"OPENAI_API_KEY":"one-secret"}"#.utf8).write(to: authURL)
        let installed = ProxyConfiguration(
            configPath: configURL.path,
            providerName: "one",
            bridgeModel: "gpt-5",
            upstreamBaseURL: "https://one.example/v1",
            localBaseURL: "http://127.0.0.1:17891/v1",
            port: 17891,
            backupPath: nil
        )
        let credentials = TestCredentialStore()
        let database = try AppDatabase(url: databaseURL)
        let migration = ProviderMigrationService(credentialStore: credentials)

        try await migration.migrateIfNeeded(
            database: database,
            configuration: installed,
            proxyPort: 17891,
            configURL: configURL,
            authURL: authURL
        )
        try await migration.migrateIfNeeded(
            database: database,
            configuration: installed,
            proxyPort: 17891,
            configURL: configURL,
            authURL: authURL
        )

        let providers = try await database.providers()
        XCTAssertEqual(providers.count, 2)
        XCTAssertEqual(providers[0].baseURL, "https://one.example/v1")
        XCTAssertEqual(try credentials.token(for: providers[0].id), "one-secret")
        XCTAssertEqual(try credentials.token(for: providers[1].id), "two-secret")
        let activeProviderID = try await database.activeProviderID()
        XCTAssertEqual(activeProviderID, providers[0].id)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), config)
        XCTAssertFalse(String(decoding: try Data(contentsOf: databaseURL), as: UTF8.self).contains("one-secret"))
        XCTAssertFalse(String(decoding: try Data(contentsOf: databaseURL), as: UTF8.self).contains("two-secret"))
    }

    func testMigratesOfficialCodexBackendAsChatGPTAccountProvider() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        let authURL = directory.appendingPathComponent("auth.json")
        let databaseURL = directory.appendingPathComponent("gptswitch.sqlite3")
        let config = """
        model = "gpt-current"
        model_provider = "chatgpt"

        [model_providers.chatgpt]
        name = "ChatGPT"
        base_url = "https://chatgpt.com/backend-api/codex/"
        """
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        try Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"secret","account_id":"account"}}"#.utf8)
            .write(to: authURL)
        let credentials = TestCredentialStore()
        let database = try AppDatabase(url: databaseURL)

        try await ProviderMigrationService(credentialStore: credentials).migrateIfNeeded(
            database: database,
            configuration: nil,
            proxyPort: 17_891,
            configURL: configURL,
            authURL: authURL
        )

        let providers = try await database.providers()
        let provider = try XCTUnwrap(providers.first)
        XCTAssertEqual(provider.credentialMode, .chatGPTAccount)
        XCTAssertEqual(provider.baseURL, ChatGPTProviderDefaults.baseURL)
        XCTAssertNil(try credentials.token(for: provider.id))
    }
}

private final class TestCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [UUID: String] = [:]

    func token(for providerID: UUID) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return tokens[providerID]
    }

    func setToken(_ token: String, for providerID: UUID) throws {
        lock.lock()
        tokens[providerID] = token
        lock.unlock()
    }

    func deleteToken(for providerID: UUID) throws {
        lock.lock()
        tokens.removeValue(forKey: providerID)
        lock.unlock()
    }
}

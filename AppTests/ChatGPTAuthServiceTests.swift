import Foundation
import XCTest
@testable import GPTSwitch

final class ChatGPTAuthServiceTests: XCTestCase {
    func testLoadsChatGPTAuthWithoutPersistingOrLoggingCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authURL = directory.appendingPathComponent("auth.json")
        let accessToken = jwt(payload: ["exp": Date().addingTimeInterval(3_600).timeIntervalSince1970])
        try writeAuth(
            [
                "auth_mode": "chatgpt",
                "tokens": [
                    "access_token": accessToken,
                    "account_id": "account-test",
                    "refresh_token": "refresh-test",
                ],
            ],
            to: authURL
        )

        let context = try ChatGPTAuthService().load(authURL: authURL)

        XCTAssertEqual(context.accessToken, accessToken)
        XCTAssertEqual(context.accountID, "account-test")
    }

    func testRejectsMissingOrNonChatGPTAuth() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingURL = directory.appendingPathComponent("missing.json")
        XCTAssertThrowsError(try ChatGPTAuthService().load(authURL: missingURL)) { error in
            XCTAssertEqual(error as? ChatGPTAuthError, .notLoggedIn)
        }

        let malformedURL = directory.appendingPathComponent("malformed.json")
        try Data(#"{"auth_mode":"apikey"}"#.utf8).write(to: malformedURL)
        XCTAssertThrowsError(try ChatGPTAuthService().load(authURL: malformedURL)) { error in
            XCTAssertEqual(error as? ChatGPTAuthError, .notLoggedIn)
        }
    }

    func testRejectsMissingAccessToken() throws {
        let authURL = try temporaryAuthURL([
            "auth_mode": "chatgpt",
            "tokens": ["account_id": "account-test"],
        ])
        defer { try? FileManager.default.removeItem(at: authURL.deletingLastPathComponent()) }

        XCTAssertThrowsError(try ChatGPTAuthService().load(authURL: authURL)) { error in
            XCTAssertEqual(error as? ChatGPTAuthError, .malformed)
        }
    }

    func testRejectsMissingAccountID() throws {
        let authURL = try temporaryAuthURL([
            "auth_mode": "chatgpt",
            "tokens": ["access_token": "access-test"],
        ])
        defer { try? FileManager.default.removeItem(at: authURL.deletingLastPathComponent()) }

        XCTAssertThrowsError(try ChatGPTAuthService().load(authURL: authURL)) { error in
            XCTAssertEqual(error as? ChatGPTAuthError, .malformed)
        }
    }

    func testRejectsInvalidJSON() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authURL = directory.appendingPathComponent("auth.json")
        try Data("not-json".utf8).write(to: authURL)

        XCTAssertThrowsError(try ChatGPTAuthService().load(authURL: authURL)) { error in
            XCTAssertEqual(error as? ChatGPTAuthError, .malformed)
        }
    }

    func testRejectsExpiredAccessToken() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authURL = directory.appendingPathComponent("auth.json")
        try writeAuth(
            [
                "auth_mode": "chatgpt",
                "tokens": [
                    "access_token": jwt(payload: ["exp": Date().addingTimeInterval(-1).timeIntervalSince1970]),
                    "account_id": "account-test",
                ],
            ],
            to: authURL
        )

        XCTAssertThrowsError(try ChatGPTAuthService().load(authURL: authURL)) { error in
            XCTAssertEqual(error as? ChatGPTAuthError, .expired)
        }
    }

    private func writeAuth(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func temporaryAuthURL(_ object: [String: Any]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let authURL = directory.appendingPathComponent("auth.json")
        try writeAuth(object, to: authURL)
        return authURL
    }

    private func jwt(payload: [String: Any]) -> String {
        let header = encoded(["alg": "none"])
        let body = encoded(payload)
        return "\(header).\(body).signature"
    }

    private func encoded(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

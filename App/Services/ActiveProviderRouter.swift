import Foundation

final class ActiveProviderRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var defaultValue: ActiveProviderSnapshot
    private var values: [UUID: ActiveProviderSnapshot]
    private var allowsCrossProviderRouting: Bool

    init(
        snapshot: ActiveProviderSnapshot,
        snapshots: [ActiveProviderSnapshot] = [],
        allowsCrossProviderRouting: Bool = false
    ) {
        defaultValue = snapshot
        values = Self.snapshotMap(default: snapshot, snapshots: snapshots)
        self.allowsCrossProviderRouting = allowsCrossProviderRouting
    }

    func snapshot() -> ActiveProviderSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return defaultValue
    }

    func update(_ snapshot: ActiveProviderSnapshot) {
        lock.lock()
        defaultValue = snapshot
        values[snapshot.id] = snapshot
        lock.unlock()
    }

    func update(default snapshot: ActiveProviderSnapshot, snapshots: [ActiveProviderSnapshot]) {
        lock.lock()
        defaultValue = snapshot
        values = Self.snapshotMap(default: snapshot, snapshots: snapshots)
        lock.unlock()
    }

    func allSnapshots() -> [ActiveProviderSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return Array(values.values)
    }

    func isCrossProviderRoutingEnabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowsCrossProviderRouting
    }

    func setAllowsCrossProviderRouting(_ enabled: Bool) {
        lock.lock()
        allowsCrossProviderRouting = enabled
        lock.unlock()
    }

    func route(model requestedModel: String?) throws -> ActiveProviderSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = requestedModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return defaultValue }

        if let route = matchingRoute(trimmed, in: defaultValue) {
            return overriding(defaultValue, with: route.modelID)
        }

        if let slash = trimmed.firstIndex(of: "/") {
            let providerName = String(trimmed[..<slash])
            let selectedModel = String(trimmed[trimmed.index(after: slash)...])
            if providerName == defaultValue.profile.configName {
                return try route(selectedModel: selectedModel, through: defaultValue)
            }
            guard allowsCrossProviderRouting else {
                throw ProviderRoutingError.modelUnavailableForCurrentProvider(
                    trimmed,
                    defaultValue.profile.displayName
                )
            }
            guard let provider = values.values.first(where: { $0.profile.configName == providerName }) else {
                throw ProviderRoutingError.unknownProvider(providerName)
            }
            return try route(selectedModel: selectedModel, through: provider)
        }

        guard allowsCrossProviderRouting else {
            throw ProviderRoutingError.modelUnavailableForCurrentProvider(
                trimmed,
                defaultValue.profile.displayName
            )
        }
        let matches = values.values.compactMap { provider -> ActiveProviderSnapshot? in
            guard provider.id != defaultValue.id,
                  let route = matchingRoute(trimmed, in: provider) else { return nil }
            return overriding(provider, with: route.modelID)
        }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { throw ProviderRoutingError.ambiguousModel(trimmed) }
        throw ProviderRoutingError.unknownModel(trimmed)
    }

    private func route(
        selectedModel: String,
        through provider: ActiveProviderSnapshot
    ) throws -> ActiveProviderSnapshot {
        guard let route = matchingRoute(selectedModel, in: provider) else {
            throw ProviderRoutingError.unknownModel("\(provider.profile.configName)/\(selectedModel)")
        }
        return overriding(provider, with: route.modelID)
    }

    private func matchingRoute(
        _ requestedModel: String,
        in provider: ActiveProviderSnapshot
    ) -> ProviderModelRoute? {
        provider.profile.effectiveModelRoutes.first {
            $0.isEnabled && ($0.modelID == requestedModel || $0.encodedModelID == requestedModel)
        }
    }

    private func overriding(
        _ provider: ActiveProviderSnapshot,
        with modelID: String
    ) -> ActiveProviderSnapshot {
        var output = provider
        output.upstreamModelOverride = modelID
        return output
    }

    private static func snapshotMap(
        default snapshot: ActiveProviderSnapshot,
        snapshots: [ActiveProviderSnapshot]
    ) -> [UUID: ActiveProviderSnapshot] {
        var output = Dictionary(
            snapshots.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        output[snapshot.id] = snapshot
        return output
    }
}

enum ProviderRoutingError: LocalizedError, Equatable {
    case unknownProvider(String)
    case unknownModel(String)
    case ambiguousModel(String)
    case modelUnavailableForCurrentProvider(String, String)

    var errorDescription: String? {
        switch self {
        case .unknownProvider(let name): "未知或不可用的 Provider：\(name)"
        case .unknownModel(let model): "未知或已停用的模型：\(model)"
        case .ambiguousModel(let model): "模型 \(model) 同时存在于多个 Provider，请使用 provider/model"
        case .modelUnavailableForCurrentProvider(let model, let provider):
            "模型 \(model) 不属于当前 Provider（\(provider)），请重新选择模型"
        }
    }
}

enum ProviderRequestAuthorizer {
    static func apply(_ provider: ActiveProviderSnapshot, to request: inout URLRequest) {
        switch provider.profile.credentialMode {
        case .keychainBearer:
            guard let token = provider.bearerToken, !token.isEmpty else { return }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(nil, forHTTPHeaderField: "api-key")
            request.setValue(nil, forHTTPHeaderField: "x-api-key")
        case .keychainAPIKey:
            guard let token = provider.bearerToken, !token.isEmpty else { return }
            request.setValue(token, forHTTPHeaderField: "x-api-key")
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue(nil, forHTTPHeaderField: "api-key")
        case .passthrough:
            break
        case .chatGPTAccount:
            if request.value(forHTTPHeaderField: "Authorization") == nil,
               let token = provider.bearerToken,
               !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil,
               let accountID = provider.chatGPTAccountID,
               !accountID.isEmpty {
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
            request.setValue(nil, forHTTPHeaderField: "api-key")
            request.setValue(nil, forHTTPHeaderField: "x-api-key")
        }
    }
}

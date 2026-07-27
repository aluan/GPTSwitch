import Observation
import SwiftUI

enum MainSection: String, CaseIterable, Hashable, Sendable {
    case providers
    case usage
    case skins
    case settings

    var title: String {
        switch self {
        case .providers: "Providers"
        case .usage: "使用统计"
        case .skins: "换肤"
        case .settings: "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .providers: "server.rack"
        case .usage: "chart.xyaxis.line"
        case .skins: "paintpalette"
        case .settings: "gearshape"
        }
    }
}

@MainActor
@Observable
final class MainNavigation {
    var section: MainSection = .providers
    var editingProviderID: UUID?
    var usageProviderFilter: UUID?

    func show(_ section: MainSection) {
        self.section = section
        if section != .providers { editingProviderID = nil }
        if section != .usage { usageProviderFilter = nil }
    }

    func editProvider(_ id: UUID) {
        section = .providers
        editingProviderID = id
    }

    func showUsage(for providerID: UUID? = nil) {
        editingProviderID = nil
        usageProviderFilter = providerID
        section = .usage
    }
}

struct ManagementView: View {
    @Bindable var model: AppModel
    @Bindable var navigation: MainNavigation
    @State private var showingNewProvider = false
    @State private var providerPendingDeletion: ProviderProfile?

    var body: some View {
        VStack(spacing: 0) {
            MainControlBar(
                model: model,
                navigation: navigation,
                canAddProvider: navigation.section == .providers && navigation.editingProviderID == nil,
                addProvider: { showingNewProvider = true }
            )
            Divider()
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.08))
            }
            content
        }
        .frame(minWidth: 760, minHeight: 520)
        .sheet(isPresented: $showingNewProvider) {
            ProviderCreateView(model: model) { providerID in
                navigation.editProvider(providerID)
            }
        }
        .confirmationDialog(
            providerPendingDeletion.map { "删除 \($0.displayName)？" } ?? "删除 Provider？",
            isPresented: deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("删除 Provider", role: .destructive) {
                guard let provider = providerPendingDeletion else { return }
                Task {
                    _ = await model.deleteProvider(provider.id)
                    providerPendingDeletion = nil
                }
            }
        } message: {
            Text("Provider 配置和对应的钥匙串密钥将被删除，此操作无法撤销。")
        }
        .onChange(of: model.providers) {
            if let id = navigation.editingProviderID,
               !model.providers.contains(where: { $0.id == id }) {
                navigation.editingProviderID = nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch navigation.section {
        case .providers:
            if let providerID = navigation.editingProviderID,
               let provider = model.providers.first(where: { $0.id == providerID }) {
                providerDetail(provider)
            } else {
                providerList
            }
        case .usage:
            UsageDashboardView(
                model: model,
                providerFilter: Binding(
                    get: { navigation.usageProviderFilter },
                    set: { navigation.usageProviderFilter = $0 }
                )
            )
        case .skins:
            SkinStudioView(model: model)
        case .settings:
            SettingsView(model: model)
        }
    }

    private var providerList: some View {
        Group {
            if model.providers.isEmpty {
                ContentUnavailableView {
                    Label("尚未添加 Provider", systemImage: "server.rack")
                } description: {
                    Text("添加一个 Responses API Provider 后即可启动本地代理。")
                } actions: {
                    Button("添加 Provider") { showingNewProvider = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(model.providers) { provider in
                        ProviderCardRow(
                            model: model,
                            navigation: navigation,
                            provider: provider,
                            edit: { navigation.editProvider(provider.id) },
                            delete: { providerPendingDeletion = provider }
                        )
                        .listRowInsets(EdgeInsets(top: 7, leading: 20, bottom: 7, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    .onMove { indices, destination in
                        var ids = model.providers.map(\.id)
                        ids.move(fromOffsets: indices, toOffset: destination)
                        model.reorderProviders(ids)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func providerDetail(_ provider: ProviderProfile) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    navigation.editingProviderID = nil
                } label: {
                    Label("返回 Providers", systemImage: "chevron.left")
                }
                .keyboardShortcut("[", modifiers: .command)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
            Divider()
            ProviderDetailView(model: model, provider: provider) {
                navigation.editingProviderID = nil
            }
            .id(provider.id)
        }
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { providerPendingDeletion != nil },
            set: { if !$0 { providerPendingDeletion = nil } }
        )
    }
}

private struct MainControlBar: View {
    @Bindable var model: AppModel
    @Bindable var navigation: MainNavigation
    let canAddProvider: Bool
    let addProvider: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text("GPTSwitch")
                .font(.title2.weight(.semibold))

            Divider()
                .frame(height: 24)

            Toggle("代理", isOn: Binding(
                get: { model.proxyEnabled },
                set: { model.setProxyEnabled($0) }
            ))
            .toggleStyle(.switch)
            .disabled(model.isProxyTransitioning || (model.activeProvider == nil && !model.proxyEnabled))

            Label(model.status.title, systemImage: model.status.symbolName)
                .font(.callout)
                .foregroundStyle(statusColor)

            Text(model.providerName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 170, alignment: .leading)

            Spacer(minLength: 12)

            Picker("主界面", selection: Binding(
                get: { navigation.section },
                set: { navigation.show($0) }
            )) {
                ForEach(MainSection.allCases, id: \.self) { section in
                    Image(systemName: section.systemImage)
                        .accessibilityLabel(section.title)
                        .tag(section)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 220)

            Spacer(minLength: 12)

            Button(action: addProvider) {
                Image(systemName: "plus")
                    .font(.headline)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Circle())
            .help("添加 Provider")
            .keyboardShortcut("n")
            .opacity(canAddProvider ? 1 : 0)
            .disabled(!canAddProvider)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var statusColor: Color {
        switch model.status {
        case .running: .green
        case .starting, .testing: .orange
        case .failed: .red
        case .notConfigured, .stopped: .secondary
        }
    }
}

private struct ProviderCardRow: View {
    @Bindable var model: AppModel
    @Bindable var navigation: MainNavigation
    let provider: ProviderProfile
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("拖动排序")

            Text(initials)
                .font(.headline)
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(provider.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    if isActive {
                        Text("当前使用")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tint)
                    }
                }
                Text(provider.baseURL)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Label(provider.healthState.title, systemImage: provider.healthState.symbolName)
                        .foregroundStyle(healthColor)
                    if let latency = provider.lastHealthLatencyMilliseconds {
                        Text("\(latency) ms")
                    }
                    if let checked = provider.lastCheckedAt {
                        Text("·")
                        Text(checked, style: .relative)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 16)

            if model.checkingProviderIDs.contains(provider.id) || (isActive && model.status == .testing) {
                ProgressView()
                    .controlSize(.small)
            }

            if isActive {
                Label("已启用", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                    .frame(width: 72)
            } else {
                Button("启用") { model.switchProvider(to: provider.id) }
                    .buttonStyle(.borderedProminent)
            }

            Button(action: edit) {
                Image(systemName: "pencil")
            }
            .help("编辑 Provider")

            Button {
                model.duplicateProvider(provider.id)
            } label: {
                Image(systemName: "square.on.square")
            }
            .help("复制 Provider")

            Menu {
                Button("端点测速") { model.measureProvider(provider.id) }
                Button("工具兼容性") { model.testProviderModel(provider.id) }
                    .help("要求模型返回原生结构化工具调用；文本 XML/JSON 不通过")
                Button("生图自检") { model.runSelfTest(for: provider.id) }
                    .disabled(!model.canRunImageSelfTest(for: provider.id))
            } label: {
                Image(systemName: "waveform.path.ecg")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Provider 检测")

            Button {
                navigation.showUsage(for: provider.id)
            } label: {
                Image(systemName: "chart.bar")
            }
            .help("查看 Provider 统计")

            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
            }
            .disabled(isActive)
            .help(isActive ? "请先启用其他 Provider" : "删除 Provider")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isActive ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isActive ? 1.5 : 1)
        }
        .contextMenu {
            Button("编辑") { edit() }
            Button("启用") { model.switchProvider(to: provider.id) }
                .disabled(isActive)
            Button("复制") { model.duplicateProvider(provider.id) }
            Divider()
            Button("删除", role: .destructive) { delete() }
                .disabled(isActive)
        }
    }

    private var isActive: Bool { provider.id == model.activeProviderID }

    private var initials: String {
        let words = provider.displayName.split(separator: " ")
        let characters = words.prefix(2).compactMap(\.first)
        return characters.isEmpty ? String(provider.displayName.prefix(1)).uppercased() : String(characters).uppercased()
    }

    private var healthColor: Color {
        switch provider.healthState {
        case .healthy: .green
        case .degraded: .orange
        case .unavailable: .red
        case .unknown: .secondary
        }
    }
}

private enum ProviderCreationTemplate: String, CaseIterable {
    case chatGPTAccount
    case responses
    case compatibleChat
    case compatibleAnthropic
    case anthropicAPI

    var title: String {
        switch self {
        case .chatGPTAccount: "ChatGPT 账号登录"
        case .responses: "Codex 原生中转站"
        case .compatibleChat: "OpenAI 兼容中转站"
        case .compatibleAnthropic: "Claude 中转站（第三方）"
        case .anthropicAPI: "Anthropic 官方"
        }
    }

    /// 面向普通用户的适用说明：按"我的服务属于哪种"来选，而非协议名。
    var description: String {
        switch self {
        case .chatGPTAccount: "复用 Codex 已登录的 ChatGPT 账号，不使用 API Key。"
        case .responses: "中转站支持 Codex 原生协议，功能最完整。如果中转站文档提到 Responses API 或可直接用于 Codex，选这个。"
        case .compatibleChat: "中转站只提供 OpenAI 兼容接口（多数国产 / 聚合 API 属于此类）。GPTSwitch 会做协议转换。"
        case .compatibleAnthropic: "第三方中转站提供 Claude 模型（走 Anthropic 协议）。区别于官方直连。"
        case .anthropicAPI: "直连 Anthropic 官方 API（api.anthropic.com），使用 Claude 模型与官方 API Key。"
        }
    }
}

private struct ProviderCreateView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let onCreated: (UUID) -> Void
    @State private var draft: ProviderProfile
    @State private var template: ProviderCreationTemplate = .responses
    @State private var apiKey = ""
    @State private var isSaving = false

    init(model: AppModel, onCreated: @escaping (UUID) -> Void) {
        self.model = model
        self.onCreated = onCreated
        let index = model.providers.count + 1
        var profile = ProviderProfile(
            configName: "provider-\(index)",
            displayName: "新 Provider",
            baseURL: "https://api.example.com/v1",
            bridgeModel: model.activeProvider?.bridgeModel ?? "gpt-5",
            sortOrder: model.providers.count
        )
        profile.models = [ProviderModelRoute(
            providerID: profile.id,
            modelID: profile.bridgeModel,
            displayName: profile.bridgeModel,
            inputModalities: ["text", "image"]
        )]
        _draft = State(initialValue: profile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加 Provider")
                .font(.title2.weight(.semibold))
            Picker("配置模板", selection: $template) {
                ForEach(ProviderCreationTemplate.allCases, id: \.self) { template in
                    Text(template.title).tag(template)
                }
            }
            .onChange(of: template) {
                applyTemplate(template)
            }
            Text(template.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            ProviderEditorForm(draft: $draft, apiKey: $apiKey, hasStoredCredential: false)
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加") {
                    isSaving = true
                    Task {
                        if let provider = await model.saveProvider(draft, apiKey: apiKey) {
                            onCreated(provider.id)
                            dismiss()
                        }
                        isSaving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(isSaving)
    }

    private func applyTemplate(_ template: ProviderCreationTemplate) {
        switch template {
        case .chatGPTAccount:
            let modelID = model.activeProvider?.effectiveModelRoutes.first?.modelID
                ?? model.activeProvider?.bridgeModel
                ?? model.inspection?.model
                ?? "gpt-5"
            draft = ChatGPTProviderDefaults.profile(
                id: draft.id,
                modelID: modelID,
                sortOrder: draft.sortOrder
            )
            apiKey = ""
        case .responses:
            draft.displayName = "Responses Provider"
            draft.baseURL = "https://api.example.com/v1"
            draft.wireProtocol = .responses
            draft.chatDialect = .standard
            draft.inferenceModel = ""
            if draft.bridgeModel.isEmpty { draft.bridgeModel = model.activeProvider?.bridgeModel ?? "gpt-5" }
            draft.website = ""
        case .compatibleChat:
            draft.displayName = "Chat Provider"
            draft.baseURL = "https://api.example.com/v1"
            draft.wireProtocol = .chatCompletions
            draft.chatDialect = .standard
            draft.inferenceModel = ""
            draft.bridgeModel = ""
            draft.website = ""
        case .compatibleAnthropic:
            draft.displayName = "Claude Relay"
            draft.baseURL = "https://api.example.com/v1"
            draft.wireProtocol = .anthropicMessages
            draft.chatDialect = .standard
            draft.inferenceModel = ""
            draft.bridgeModel = ""
            draft.credentialMode = .keychainBearer
            draft.website = ""
        case .anthropicAPI:
            draft.displayName = "Anthropic"
            draft.baseURL = "https://api.anthropic.com"
            draft.wireProtocol = .anthropicMessages
            draft.chatDialect = .standard
            draft.inferenceModel = "claude-sonnet-4-6"
            draft.bridgeModel = ""
            draft.credentialMode = .keychainAPIKey
            draft.website = "https://console.anthropic.com"
        }
        draft.testModel = ""
        let defaultModel = draft.wireProtocol == .responses ? draft.bridgeModel : draft.inferenceModel
        draft.models = defaultModel.isEmpty ? [] : [ProviderModelRoute(
            providerID: draft.id,
            modelID: defaultModel,
            displayName: defaultModel,
            inputModalities: draft.wireProtocol == .responses ? ["text", "image"] : ["text"]
        )]
    }
}

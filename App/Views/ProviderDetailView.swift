import SwiftUI

struct ProviderDetailView: View {
    @Bindable var model: AppModel
    let provider: ProviderProfile
    let onDeleted: () -> Void
    @State private var draft: ProviderProfile
    @State private var apiKey = ""
    @State private var showingDeleteConfirmation = false
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var isDiscovering = false

    init(model: AppModel, provider: ProviderProfile, onDeleted: @escaping () -> Void) {
        self.model = model
        self.provider = provider
        self.onDeleted = onDeleted
        _draft = State(initialValue: provider)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                GroupBox("Provider 配置") {
                    ProviderEditorForm(
                        draft: $draft,
                        apiKey: $apiKey,
                        hasStoredCredential: model.providerHasCredential(provider.id),
                        isDiscovering: isDiscovering,
                        onDiscoverModels: draft.credentialMode == .chatGPTAccount ? nil : discoverModels
                    )
                    .padding(.top, 4)
                }
                health
                actions
                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle(provider.displayName)
        .onChange(of: provider.updatedAt) {
            draft = provider
        }
        .confirmationDialog(
            "删除 \(provider.displayName)？",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除 Provider", role: .destructive) {
                isDeleting = true
                Task {
                    if await model.deleteProvider(provider.id) {
                        onDeleted()
                    } else {
                        isDeleting = false
                    }
                }
            }
        } message: {
            Text("Provider 配置和对应的钥匙串密钥将被删除，此操作无法撤销。")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.displayName)
                    .font(.largeTitle.weight(.semibold))
                Text(provider.baseURL)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if provider.id == model.activeProviderID {
                Label("当前使用", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("启用") { model.switchProvider(to: provider.id) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var health: some View {
        GroupBox("健康检查") {
            HStack(spacing: 16) {
                Label(provider.healthState.title, systemImage: provider.healthState.symbolName)
                if let latency = provider.lastHealthLatencyMilliseconds {
                    Text("\(latency) ms")
                        .foregroundStyle(.secondary)
                }
                if let checked = provider.lastCheckedAt {
                    Text(checked, style: .relative)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .opacity(isChecking ? 1 : 0)
                Button("端点测速") { model.measureProvider(provider.id) }
                Button("工具兼容性") { model.testProviderModel(provider.id) }
                    .help("要求模型返回原生结构化工具调用；文本 XML/JSON 不通过")
                Button("生图自检") { model.runSelfTest(for: provider.id) }
                    .disabled(!model.canRunImageSelfTest(for: provider.id))
                    .help(imageSelfTestHelp)
            }
            if let message = provider.lastHealthError {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
        }
    }

    private var isChecking: Bool {
        model.checkingProviderIDs.contains(provider.id)
            || (provider.id == model.activeProviderID && model.status == .testing)
    }

    private var imageSelfTestHelp: String {
        if !provider.supportsImageBridge {
            return "当前 Provider 协议不支持 Images API"
        }
        if provider.id != model.activeProviderID {
            return "请先启用此 Provider"
        }
        if model.status == .testing {
            return "生图自检正在运行"
        }
        if !model.isRunning {
            return "请先启动本地代理"
        }
        return "通过本地代理执行一次真实生图请求"
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("保存更改") {
                    isSaving = true
                    Task {
                        if await model.saveProvider(draft, apiKey: apiKey.isEmpty ? nil : apiKey) != nil {
                            apiKey = ""
                        }
                        isSaving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || isDeleting)

                Button("还原") {
                    draft = provider
                    apiKey = ""
                }
                .disabled((draft == provider && apiKey.isEmpty) || isSaving || isDeleting)

                Button("复制") { model.duplicateProvider(provider.id) }
                    .disabled(isSaving || isDeleting)

                if model.providerHasCredential(provider.id) {
                    Button("删除密钥", role: .destructive) {
                        model.deleteProviderCredential(provider.id)
                    }
                    .disabled(isSaving || isDeleting)
                }

                Spacer()

                Button("删除 Provider", role: .destructive) {
                    showingDeleteConfirmation = true
                }
                .disabled(provider.id == model.activeProviderID || isSaving || isDeleting)
                .help(provider.id == model.activeProviderID
                    ? "请先启用其他 Provider，再删除当前 Provider"
                    : "删除此 Provider")
            }

            if provider.id == model.activeProviderID {
                Text("当前 Provider 不能删除；请先启用另一个 Provider。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func discoverModels() {
        isDiscovering = true
        Task {
            if let routes = await model.discoverProviderModels(provider.id) {
                draft.models = routes
            }
            isDiscovering = false
        }
    }
}

struct ProviderEditorForm: View {
    @Binding var draft: ProviderProfile
    @Binding var apiKey: String
    let hasStoredCredential: Bool
    var isDiscovering = false
    var onDiscoverModels: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            row("显示名称") {
                TextField("Provider 名称", text: $draft.displayName)
            }
            row("配置标识") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("唯一标识，如 aigocode-claude", text: $draft.configName)
                        .autocorrectionDisabled()
                        .disabled(draft.credentialMode == .chatGPTAccount)
                    Text("需唯一，用作跨 Provider 路由标识。开启后可用「标识/模型名」指定其他 Provider；服务商名请填到「显示名称」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            row("API 地址") {
                TextField("https://api.example.com/v1", text: $draft.baseURL)
                    .disabled(draft.credentialMode == .chatGPTAccount)
            }
            row("API 协议") {
                Picker("", selection: $draft.wireProtocol) {
                    ForEach(ProviderWireProtocol.allCases, id: \.self) { wireProtocol in
                        Text(wireProtocol.title).tag(wireProtocol)
                    }
                }
                .labelsHidden()
                .disabled(draft.credentialMode == .chatGPTAccount)
            }
            if draft.wireProtocol != .responses {
                if draft.wireProtocol == .chatCompletions {
                    row("兼容类型") {
                        Picker("", selection: $draft.chatDialect) {
                            ForEach(ChatCompletionsDialect.allCases, id: \.self) { dialect in
                                Text(dialect.title).tag(dialect)
                            }
                        }
                        .labelsHidden()
                    }
                }
                row("推理模型") {
                    TextField(draft.wireProtocol == .anthropicMessages ? "claude-opus-4-8" : "model-id", text: $draft.inferenceModel)
                }
            } else {
                row("桥接模型") {
                    TextField("gpt-5", text: $draft.bridgeModel)
                }
            }
            row("测试模型") {
                TextField("留空则使用当前模型", text: $draft.testModel)
            }
            row("认证方式") {
                Picker("", selection: $draft.credentialMode) {
                    ForEach(availableCredentialModes, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .onChange(of: draft.credentialMode) {
                    guard draft.credentialMode == .chatGPTAccount else { return }
                    draft.baseURL = ChatGPTProviderDefaults.baseURL
                    draft.wireProtocol = .responses
                }
            }
            if draft.credentialMode == .keychainBearer || draft.credentialMode == .keychainAPIKey {
                row("API Key") {
                    VStack(alignment: .leading, spacing: 4) {
                        SecureField(hasStoredCredential ? "留空以保留现有密钥" : "输入 API Key", text: $apiKey)
                        Text(hasStoredCredential ? "密钥已保存在 macOS 钥匙串" : "密钥不会写入数据库或日志")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            row("成本倍率") {
                TextField("1.0", value: $draft.costMultiplier, format: .number.precision(.fractionLength(0...3)))
                    .frame(width: 120)
            }
            row("网站") {
                TextField("https://provider.example.com", text: $draft.website)
            }
            row("备注") {
                TextField("用途、套餐或到期时间", text: $draft.note, axis: .vertical)
                    .lineLimit(2...4)
            }
            }
            Divider()
            ProviderModelsEditor(
                providerID: draft.id,
                routes: $draft.models,
                isDiscovering: isDiscovering,
                onDiscover: onDiscoverModels
            )
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            content()
        }
    }

    private var availableCredentialModes: [ProviderCredentialMode] {
        switch draft.wireProtocol {
        case .responses:
            return [.keychainBearer, .passthrough, .chatGPTAccount]
        case .chatCompletions:
            return [.keychainBearer, .passthrough]
        case .anthropicMessages:
            return [.keychainAPIKey, .keychainBearer, .passthrough]
        }
    }
}

private struct ProviderModelsEditor: View {
    let providerID: UUID
    @Binding var routes: [ProviderModelRoute]
    let isDiscovering: Bool
    let onDiscover: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex 模型目录")
                        .font(.headline)
                    Text("选择器使用 provider/model；上游仍收到原始模型 ID。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let onDiscover {
                    Button("从 /models 刷新", action: onDiscover)
                        .disabled(isDiscovering)
                }
                Button("添加模型") { addRoute() }
            }
            if routes.isEmpty {
                Text("未单独登记模型，将使用上方默认模型生成兼容目录项。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach($routes) { $route in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("上游模型 ID", text: $route.modelID)
                        TextField("选择器显示名称", text: $route.displayName)
                        Toggle("启用", isOn: $route.isEnabled)
                            .toggleStyle(.checkbox)
                        Button(role: .destructive) {
                            routes.removeAll { $0.id == route.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    HStack {
                        TextField("推理档位：low, medium, high", text: reasoningBinding($route))
                        TextField("默认档位", text: $route.defaultReasoningEffort)
                            .frame(width: 100)
                        Toggle("图片输入", isOn: imageBinding($route))
                            .toggleStyle(.checkbox)
                    }
                    TextField("模型说明（可选）", text: $route.modelDescription)
                }
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func addRoute() {
        routes.append(ProviderModelRoute(
            providerID: providerID,
            modelID: "",
            reasoningEfforts: ["low", "medium", "high"],
            sortOrder: routes.count
        ))
    }

    private func reasoningBinding(_ route: Binding<ProviderModelRoute>) -> Binding<String> {
        Binding(
            get: { route.wrappedValue.reasoningEfforts.joined(separator: ", ") },
            set: { value in
                route.wrappedValue.reasoningEfforts = value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private func imageBinding(_ route: Binding<ProviderModelRoute>) -> Binding<Bool> {
        Binding(
            get: { route.wrappedValue.inputModalities.contains("image") },
            set: { enabled in
                route.wrappedValue.inputModalities.removeAll { $0 == "image" }
                if enabled { route.wrappedValue.inputModalities.append("image") }
            }
        )
    }
}

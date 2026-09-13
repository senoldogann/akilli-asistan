import SwiftUI
import AppKit

struct SettingsView: View {
    @Binding var isPresented: Bool
    @Bindable var viewModel: SettingsViewModel
    @Bindable var providerViewModel: ProviderViewModel

    @State private var selectedDomain: SettingsDomain? = .providers
    @State private var tavilyKeyInput = ""
    @State private var groqKeyInput = ""
    @State private var isClearingMemory = false

    @AppStorage("fontSize") private var fontSize: Double = 14
    @AppStorage("fontDesign") private var fontDesign: String = "monospaced"
    @AppStorage("windowWidth") private var windowWidth: Double = 450
    @AppStorage("windowHeight") private var windowHeight: Double = 400
    @AppStorage("windowOpacity") private var windowOpacity: Double = 1
    @AppStorage("selectedThemeName") private var selectedTheme: String = "Red"
    @AppStorage("autoAnalyze") private var autoAnalyze = true
    @AppStorage("stealthModeEnabled") private var stealthMode = false
    @AppStorage("useExternalAudio") private var useExternalAudio = true
    @AppStorage("audioLanguage") private var audioLanguage = "auto"
    @AppStorage("streamingMode") private var streamingMode = "streaming"
    @AppStorage("streamingSpeed") private var streamingSpeed = "normal"

    var body: some View {
        NavigationSplitView {
            List(SettingsDomain.allCases, selection: $selectedDomain) { domain in
                Label(domain.rawValue, systemImage: domain.systemImage)
                    .tag(Optional(domain))
            }
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            VStack(spacing: 0) {
                detailHeader
                Divider()
                ScrollView {
                    selectedSection
                        .frame(maxWidth: 760, alignment: .topLeading)
                        .padding(24)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 700, minHeight: 620)
        .task {
            await providerViewModel.refresh()
            _ = await viewModel.reloadIntegrations()
            await viewModel.refreshMemoryState()
        }
    }

    private var detailHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedDomain?.rawValue ?? SettingsDomain.providers.rawValue)
                    .font(.title2.weight(.semibold))
                Text("ZeroLose runtime configuration")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var selectedSection: some View {
        switch selectedDomain ?? .providers {
        case .providers: providersSection
        case .tools: toolsSection
        case .runtime: runtimeSection
        case .memory: memorySection
        case .voice: voiceSection
        case .appearance: appearanceSection
        case .privacy: privacyDiagnosticsSection
        }
    }

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(
                title: "Providers",
                subtitle: "Registered V2 model providers and the authoritative model selection."
            ) {
                ProviderSelectorView(viewModel: providerViewModel)

                Divider()

                ForEach(providerViewModel.snapshot.providers) { provider in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName)
                                    .font(.headline)
                                Text(provider.id.rawValue)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(provider.availability.rawValue)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(providerStatusColor(provider.availability))
                        }

                        if provider.models.isEmpty {
                            Text(provider.modelDiscoveryState == .failed ? "Model discovery failed." : "No discovered models.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(provider.models.map(\.displayName).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }

            SettingsCard(
                title: "OpenAI API Credential",
                subtitle: "Stored in Keychain. The saved secret is never read back into the interface."
            ) {
                HStack {
                    Label(
                        providerViewModel.openAIKeyConfigured ? "Configured" : "Not configured",
                        systemImage: providerViewModel.openAIKeyConfigured ? "checkmark.circle.fill" : "circle"
                    )
                    .foregroundStyle(providerViewModel.openAIKeyConfigured ? Color.green : Color.secondary)
                    Spacer()
                }

                SecureField("Paste API key", text: $providerViewModel.openAIAPIKeyInput)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save") {
                        let value = providerViewModel.openAIAPIKeyInput
                        Task { await providerViewModel.saveOpenAIAPIKey(value) }
                    }
                    .disabled(providerViewModel.openAIAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Remove", role: .destructive) {
                        Task { await providerViewModel.removeOpenAIAPIKey() }
                    }
                    .disabled(!providerViewModel.openAIKeyConfigured)

                    Spacer()
                    if let error = providerViewModel.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(
                title: "Tools",
                subtitle: "Credentials used by tool integrations are separate from model providers."
            ) {
                integrationCredentialRow(
                    title: "Tavily Web Search",
                    description: "Optional web-search integration credential.",
                    credential: .tavily,
                    input: $tavilyKeyInput
                )
            }
        }
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(
                title: "Runtime",
                subtitle: "Authority and execution behavior for V2 commands."
            ) {
                Picker("Authority mode", selection: authorityModeBinding) {
                    Text("Manual approval").tag(AuthorityMode.manual)
                    Text("Auto approval").tag(AuthorityMode.auto)
                    Text("Autonomous").tag(AuthorityMode.autonomous)
                }
                .pickerStyle(.segmented)

                Toggle("Automatically analyze relevant screen context", isOn: $autoAnalyze)

                HStack {
                    Text("Current provider")
                    Spacer()
                    Text(providerViewModel.selectedProvider?.displayName ?? "Unavailable")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Chat readiness")
                    Spacer()
                    readinessLabel(providerViewModel.canUseChat)
                }
                HStack {
                    Text("Agent readiness")
                    Spacer()
                    readinessLabel(providerViewModel.canUseAgent)
                }
            }
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(
                title: "Memory",
                subtitle: "Inspect and clear persisted semantic memory state."
            ) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Indexed chunks")
                            .font(.headline)
                        Text(viewModel.memoryStatus.isEmpty ? "Memory status not loaded." : viewModel.memoryStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(viewModel.memoryChunkCount)")
                        .font(.title3.monospacedDigit().weight(.semibold))
                }

                HStack {
                    Button("Refresh") {
                        Task { await viewModel.refreshMemoryState() }
                    }
                    Button("Clear Memory", role: .destructive) {
                        guard !isClearingMemory else { return }
                        isClearingMemory = true
                        Task { @MainActor in
                            await viewModel.clearMemory()
                            isClearingMemory = false
                        }
                    }
                    .disabled(isClearingMemory)
                    Spacer()
                }
            }
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(
                title: "Voice",
                subtitle: "Transcription and listening configuration."
            ) {
                integrationCredentialRow(
                    title: "Groq Transcription",
                    description: "Optional credential for external speech transcription.",
                    credential: .groq,
                    input: $groqKeyInput
                )

                Divider()

                Toggle("Use external audio transcription when available", isOn: $useExternalAudio)

                Picker("Audio language", selection: $audioLanguage) {
                    Text("Automatic").tag("auto")
                    Text("English").tag("en")
                    Text("Turkish").tag("tr")
                    Text("Finnish").tag("fi")
                }

                Picker("Streaming", selection: $streamingMode) {
                    Text("Streaming").tag("streaming")
                    Text("Buffered").tag("buffered")
                }

                Picker("Response pace", selection: $streamingSpeed) {
                    Text("Compact").tag("fast")
                    Text("Normal").tag("normal")
                    Text("Deliberate").tag("slow")
                }
            }
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(
                title: "Appearance",
                subtitle: "Main window typography, dimensions, opacity, and accent theme."
            ) {
                Picker("Font design", selection: $fontDesign) {
                    Text("Monospaced").tag("monospaced")
                    Text("Rounded").tag("rounded")
                    Text("Default").tag("default")
                    Text("Serif").tag("serif")
                }

                valueSlider(title: "Font size", value: $fontSize, range: 10...24, suffix: " pt")
                valueSlider(title: "Window width", value: $windowWidth, range: 350...800, suffix: " pt")
                    .onChange(of: windowWidth) { _, _ in applyWindowGeometry() }
                valueSlider(title: "Window height", value: $windowHeight, range: 300...1000, suffix: " pt")
                    .onChange(of: windowHeight) { _, _ in applyWindowGeometry() }
                valueSlider(title: "Window opacity", value: $windowOpacity, range: 0.35...1, suffix: "")
                    .onChange(of: windowOpacity) { _, value in
                        WindowManager.shared.updateWindowOpacity(value)
                    }

                Picker("Accent theme", selection: $selectedTheme) {
                    ForEach(["Red", "Blue", "Green", "Purple", "Orange"], id: \.self) { theme in
                        Text(theme).tag(theme)
                    }
                }
            }
        }
    }

    private var privacyDiagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(
                title: "Privacy & Diagnostics",
                subtitle: "Screen visibility, macOS permissions, and presentation-safe runtime state."
            ) {
                Toggle("Hide ZeroLose windows from screen capture", isOn: $stealthMode)
                    .onChange(of: stealthMode) { _, enabled in
                        WindowManager.shared.updateSharingType(stealth: enabled)
                    }

                HStack {
                    Button("Screen Recording") { openPrivacyPane("Privacy_ScreenCapture") }
                    Button("Microphone") { openPrivacyPane("Privacy_Microphone") }
                    Button("Accessibility") { openPrivacyPane("Privacy_Accessibility") }
                }

                Divider()

                diagnosticRow("Provider revision", value: String(providerViewModel.snapshot.selection.revision))
                diagnosticRow("Selected provider", value: providerViewModel.snapshot.selection.providerID.rawValue)
                diagnosticRow("Selected model", value: providerViewModel.snapshot.selection.modelID)
                diagnosticRow("Tavily configured", value: yesNo(viewModel.isIntegrationConfigured(.tavily)))
                diagnosticRow("Groq configured", value: yesNo(viewModel.isIntegrationConfigured(.groq)))
            }
        }
    }

    private var authorityModeBinding: Binding<AuthorityMode> {
        Binding(
            get: { viewModel.authorityMode },
            set: { mode in
                Task {
                    do {
                        try await viewModel.setAuthorityMode(mode)
                    } catch {
                        // Runtime projections remain authoritative; failed commands
                        // simply leave the current projected mode unchanged.
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func integrationCredentialRow(
        title: String,
        description: String,
        credential: IntegrationCredential,
        input: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(
                    viewModel.isIntegrationConfigured(credential) ? "Configured" : "Not configured",
                    systemImage: viewModel.isIntegrationConfigured(credential) ? "checkmark.circle.fill" : "circle"
                )
                .font(.caption)
                .foregroundStyle(viewModel.isIntegrationConfigured(credential) ? Color.green : Color.secondary)
            }

            SecureField("Paste credential", text: input)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Save") {
                    let value = input.wrappedValue
                    input.wrappedValue = ""
                    Task { await viewModel.saveIntegrationCredential(value, for: credential) }
                }
                .disabled(input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Remove", role: .destructive) {
                    input.wrappedValue = ""
                    Task { await viewModel.removeIntegrationCredential(credential) }
                }
                .disabled(!viewModel.isIntegrationConfigured(credential))
                Spacer()
            }
        }
    }

    private func readinessLabel(_ ready: Bool) -> some View {
        Label(ready ? "Ready" : "Unavailable", systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.circle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(ready ? Color.green : Color.secondary)
    }

    private func providerStatusColor(_ availability: ProviderAvailability) -> Color {
        switch availability {
        case .ready, .detected: return .green
        case .loginRequired, .configurationRequired: return .orange
        case .notInstalled, .unavailable, .unsupportedVersion: return .secondary
        }
    }

    private func valueSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue, specifier: "%.0f")\(suffix)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func diagnosticRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func applyWindowGeometry() {
        WindowManager.shared.updateMainWindowSize(
            width: windowWidth,
            height: windowHeight
        )
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }
}

private enum SettingsDomain: String, CaseIterable, Identifiable {
    case providers = "Providers"
    case tools = "Tools"
    case runtime = "Runtime"
    case memory = "Memory"
    case voice = "Voice"
    case appearance = "Appearance"
    case privacy = "Privacy & Diagnostics"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .providers: return "cpu"
        case .tools: return "wrench.and.screwdriver"
        case .runtime: return "bolt.horizontal.circle"
        case .memory: return "brain"
        case .voice: return "waveform"
        case .appearance: return "paintbrush"
        case .privacy: return "lock.shield"
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Liquid Glass helper

/// Applies the native macOS 26 Liquid Glass effect when available, otherwise
/// falls back to the existing frosted material. Used so every surface degrades
/// gracefully on older OSes while looking native on macOS 26+.
struct LiquidGlassSurface: ViewModifier {
    var tint: Color = .white.opacity(0.12)
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

extension View {
    func liquidGlassSurface(tint: Color = .white.opacity(0.12), cornerRadius: CGFloat = 14) -> some View {
        modifier(LiquidGlassSurface(tint: tint, cornerRadius: cornerRadius))
    }
}

/// Global window glass: applies native Liquid Glass on macOS 26+ and keeps the
/// existing frosted material fallback elsewhere.
struct LiquidGlassMainSurface: ViewModifier {
    var tint: Color = .white.opacity(0.12)

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: 20))
        } else {
            content
        }
    }
}

struct ContentView: View {
    @Bindable var viewModel: ShellViewModel
    @Bindable var chatViewModel: ChatViewModel
    @Bindable var settingsViewModel: SettingsViewModel
    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool
    @State private var isNearBottom: Bool = true
    @State private var isHistoryPresented: Bool = false
    @State private var isInterviewVaultPresented: Bool = false
    @State private var isMockInterviewPresented: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var isKeyboardDisguisePresented: Bool = false
    @State private var commandErrorMessage: String?

    // User Settings
    @AppStorage("fontSize") private var fontSize: Double = 14.0
    @AppStorage("fontDesign") private var fontDesignStr: String = "monospaced"
    @AppStorage("selectedThemeName") private var selectedTheme: String = "Red"
    @AppStorage("forceWebSearch") private var forceWebSearch: Bool = false
    @AppStorage("reasoning_effort_openai") private var openAIReasoningEffort: String = "high"
    @AppStorage("reasoning_effort_deepseek") private var deepSeekReasoningEffort: String = "high"
    @AppStorage("reasoning_effort_opencode_zen") private var openCodeZenReasoningEffort: String = "high"
    @AppStorage("reasoning_effort_opencode_go") private var openCodeGoReasoningEffort: String = "high"
    @AppStorage("reasoning_effort_ollama") private var ollamaReasoningEffort: String = ""
    @AppStorage("windowOpacity") private var windowOpacity: Double = 1.0
    @AppStorage("llm_provider") private var llmProviderRaw: String = LLMProvider.ollama.rawValue
    @AppStorage("customOpenAIReasoningModel") private var customOpenAIReasoningModel: String = ""
    @AppStorage("customDeepSeekReasoningModel") private var customDeepSeekReasoningModel: String = ""
    @AppStorage("customOpenCodeZenReasoningModel") private var customOpenCodeZenReasoningModel: String = ""
    @AppStorage("customOpenCodeGoReasoningModel") private var customOpenCodeGoReasoningModel: String = ""
    @AppStorage("customOllamaReasoningModel") private var customOllamaReasoningModel: String = ""

    var fontDesign: Font.Design {
        switch fontDesignStr {
        case "serif":   return .serif
        case "rounded": return .rounded
        case "default": return .default
        default:        return .monospaced
        }
    }

    private var themeColor: Color {
        ThemeStore.accent(for: selectedTheme)
    }

    private var activeProvider: LLMProvider {
        LLMProvider(rawValue: llmProviderRaw) ?? .ollama
    }

    private var activeReasoningModel: String {
        switch activeProvider {
        case .openAI:
            return customOpenAIReasoningModel.isEmpty ? AIModelNames.reasoning(forProvider: .openAI) : customOpenAIReasoningModel
        case .deepSeek:
            return customDeepSeekReasoningModel.isEmpty ? AIModelNames.reasoning(forProvider: .deepSeek) : customDeepSeekReasoningModel
        case .openCodeZen:
            return customOpenCodeZenReasoningModel.isEmpty ? AIModelNames.reasoning(forProvider: .openCodeZen) : customOpenCodeZenReasoningModel
        case .openCodeGo:
            return customOpenCodeGoReasoningModel.isEmpty ? AIModelNames.reasoning(forProvider: .openCodeGo) : customOpenCodeGoReasoningModel
        case .ollama:
            return customOllamaReasoningModel.isEmpty ? AIModelNames.reasoning(forProvider: .ollama) : customOllamaReasoningModel
        }
    }

    private var selectedReasoningEffort: String {
        switch activeProvider {
        case .openAI: return openAIReasoningEffort
        case .deepSeek: return deepSeekReasoningEffort
        case .openCodeZen: return openCodeZenReasoningEffort
        case .openCodeGo: return openCodeGoReasoningEffort
        case .ollama: return ollamaReasoningEffort
        }
    }

    private var supportedReasoningEfforts: [String] {
        AIModelNames.reasoningEffortOptions(for: activeProvider, model: activeReasoningModel)
    }

    private func setReasoningEffort(_ effort: String) {
        switch activeProvider {
        case .openAI: openAIReasoningEffort = effort
        case .deepSeek: deepSeekReasoningEffort = effort
        case .openCodeZen: openCodeZenReasoningEffort = effort
        case .openCodeGo: openCodeGoReasoningEffort = effort
        case .ollama: ollamaReasoningEffort = effort
        }
    }

    private var approvalLabel: String {
        switch settingsViewModel.authorityMode {
        case .manual: return "Onay İste"
        case .auto: return "Oto Onay"
        case .autonomous: return "Otonom"
        case .fullAccess: return "Oto Onay"
        }
    }

    private var modelOptions: [String] {
        switch activeProvider {
        case .openAI: return [AIModelNames.reasoning(forProvider: .openAI), AIModelNames.fast(forProvider: .openAI), AIModelNames.coding(forProvider: .openAI)]
        case .deepSeek: return [AIModelNames.reasoning(forProvider: .deepSeek), AIModelNames.fast(forProvider: .deepSeek), AIModelNames.coding(forProvider: .deepSeek)]
        case .openCodeZen: return [AIModelNames.reasoning(forProvider: .openCodeZen), AIModelNames.fast(forProvider: .openCodeZen), AIModelNames.coding(forProvider: .openCodeZen)]
        case .openCodeGo: return [AIModelNames.reasoning(forProvider: .openCodeGo), AIModelNames.fast(forProvider: .openCodeGo), AIModelNames.coding(forProvider: .openCodeGo)]
        case .ollama: return [AIModelNames.reasoning(forProvider: .ollama), AIModelNames.fast(forProvider: .ollama), AIModelNames.coding(forProvider: .ollama)]
        }
    }

    // Slash Command State
    @State private var showSlashCommands: Bool = false
    @State private var slashCommandFilter: String = ""
    @State private var selectedSlashIndex: Int = 0
    @State private var suppressNextSlashDetection: Bool = false
    @State private var slashKeyMonitor: Any?

    var filteredSlashCommands: [SlashCommand] {
        matchingSlashCommands(for: slashCommandFilter)
    }

    var body: some View {
        mainLayout
            .overlay(modalLayer)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: inputText) { _, newValue in
                if suppressNextSlashDetection {
                    suppressNextSlashDetection = false
                    return
                }
                detectSlashCommand(newValue)
            }
            .onAppear {
                installSlashKeyMonitor()
                refreshModelCatalog()
            }
            .onChange(of: llmProviderRaw) { _, _ in
                // The provider just changed: reload the model catalog so the
                // input picker shows the new provider's live models immediately
                // instead of requiring a view re-render to reveal them.
                refreshModelCatalog()
            }
            .onDisappear { removeSlashKeyMonitor() }
    }

    /// Populate the provider model list in the background so the input picker
    /// shows live models without forcing the user to open Settings first.
    private func refreshModelCatalog() {
        let credentialProvider = credentialProvider(for: activeProvider)
        Task { @MainActor in
            _ = await settingsViewModel.reloadCredentials()
            _ = await settingsViewModel.refreshModels(for: credentialProvider)
        }
    }

    private func credentialProvider(for provider: LLMProvider) -> CredentialProvider {
        switch provider {
        case .openAI: return .openAI
        case .deepSeek: return .deepSeek
        case .openCodeZen: return .openCodeZen
        case .openCodeGo: return .openCodeGo
        case .ollama: return .ollama
        }
    }

    // MARK: - Main Layout

    private var mainLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()
                .overlay(Color.glassStroke)

            scrollableContent
                .padding(.horizontal, 4)

            Divider()
                .overlay(Color.glassStroke)

            inputBar
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .background {
            // Liquid Glass base: real-time blur + frosted glass
            ZStack {
                if #available(macOS 26.0, *) {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                } else {
                    Rectangle()
                        .fill(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.96))
                }

                // Subtle noise texture layer for depth
                Color.white.opacity(0.022)
                    .blendMode(.overlay)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: selectedTheme)
        .modifier(LiquidGlassMainSurface(tint: themeColor.opacity(0.16)))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            // Glass border — inner ring
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.glassStrokeHi, Color.glassStroke, Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        }
        .shadow(color: Color.glassShadow, radius: 32, x: 0, y: 12)
        .shadow(color: Color.black.opacity(0.2), radius: 6, x: 0, y: 2)
    }

    // MARK: - Modal Layer

    @ViewBuilder
    private var modalLayer: some View {
        Group {
            if let activeAction = viewModel.activeAction {
                VStack {
                    ActionHUDView(action: activeAction)
                        .padding(.top, 20)
                    Spacer()
                }
                .zIndex(150)
            }

            if isInterviewVaultPresented {
                ZStack {
                    Color.black.opacity(windowOpacity * 0.5)
                        .ignoresSafeArea()
                        .onTapGesture { dismissInterviewVault() }

                    InterviewVaultView(isPresented: $isInterviewVaultPresented) {
                        viewModel.warmUpInterviewContext()
                    }
                    .shadow(color: .black.opacity(0.5), radius: 40)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(100)
            }

            if isMockInterviewPresented {
                ZStack {
                    Color.black.opacity(windowOpacity * 0.5)
                        .ignoresSafeArea()
                        .onTapGesture {
                            MockInterviewService.shared.endSession()
                            isMockInterviewPresented = false
                        }

                    MockInterviewView(isPresented: $isMockInterviewPresented)
                        .shadow(color: .black.opacity(0.5), radius: 40)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(100)
            }

            if isKeyboardDisguisePresented {
                ZStack {
                    Color.black.opacity(windowOpacity * 0.35)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation { isKeyboardDisguisePresented = false }
                        }

                    KeyboardDisguiseView(isPresented: $isKeyboardDisguisePresented)
                        .shadow(color: .black.opacity(0.5), radius: 40)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(110)
            }
        }
    }

    // MARK: - Slash Command Overlay

    @ViewBuilder
    private var slashCommandOverlay: some View {
        if showSlashCommands && !filteredSlashCommands.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Slash Actions")
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filteredSlashCommands.enumerated()), id: \.element.id) { index, cmd in
                                Button(action: { applySlashCommand(cmd) }) {
                                    HStack(spacing: 10) {
                                        Text(cmd.command)
                                            .font(.system(.subheadline, design: .monospaced).weight(.bold))
                                            .foregroundStyle(themeColor)

                                        Text(cmd.description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)

                                        Spacer()

                                        Text(cmd.category)
                                            .font(.caption2)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(Color.glassStroke)
                                            .clipShape(Capsule())
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(index == selectedSlashIndex ? themeColor.opacity(0.15) : Color.clear)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.interactive)
                                .id(cmd.id)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .onAppear { scrollSelectedSlashCommand(into: proxy, animated: false) }
                    .onChange(of: selectedSlashIndex) { _, _ in scrollSelectedSlashCommand(into: proxy, animated: true) }
                    .onChange(of: slashCommandFilter) { _, _ in scrollSelectedSlashCommand(into: proxy, animated: false) }
                }
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.glassStroke, lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Header Bar

    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 4) {
            // App icon + title
            HStack(spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        isKeyboardDisguisePresented = true
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(viewModel.isBusy ? Color.cyan : Color.textSecondary)
                            .symbolEffect(.pulse, isActive: viewModel.isBusy)

                        Text("Keyboard")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(.primary)
                            .tracking(1.2)
                    }
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Keyboard Settings")
            }

            Spacer()

            // Status
            statusIndicator

            // ─── Action Buttons ───
            headerButton(icon: .clipboard, activeColor: .green, isActive: viewModel.isClipboardActive, help: "Toggle Clipboard Auto-Answer") {
                viewModel.toggleClipboard()
            }

            headerButton(icon: .trash, activeColor: themeColor.opacity(0.7), isActive: false, help: "Clear Chat History") {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { viewModel.clearHistory() }
            }

            headerButton(icon: .textbubble, activeColor: themeColor.opacity(0.7), isActive: false, help: "Interview Notes") {
                WindowManager.shared.toggleTeleprompterWindow()
            }

            headerButton(icon: .book, activeColor: themeColor.opacity(0.7), isActive: false, help: "Interview Prep Vault") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isInterviewVaultPresented = true }
            }

            headerButton(icon: .person, activeColor: themeColor.opacity(0.7), isActive: false, help: "AI Mock Interview") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isMockInterviewPresented = true }
            }

            headerButton(icon: .gear, activeColor: themeColor, isActive: false, help: "Settings") {
                WindowManager.shared.toggleSettingsWindow()
            }
        }
    }

    @ViewBuilder
    private func headerButton(
        icon: ZeroLoseIcon.IconType,
        activeColor: Color,
        isActive: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZeroLoseIcon(type: icon, color: isActive ? activeColor : Color.textSecondary, size: 17)
                .frame(width: 30, height: 30)
                .background(isActive ? activeColor.opacity(0.14) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.interactive)
        .pointerCursor()
        .help(help)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isActive)
    }

    // MARK: - Status Indicator

    private var statusIndicator: some View {
        HStack(spacing: 6) {
            if viewModel.isIndexing {
                ProgressView()
                    .controlSize(.mini)
                    .tint(themeColor)
            }

            if viewModel.statusMessage.contains("Capturing") || viewModel.statusMessage.contains("Analyzing") {
                ZeroLoseIcon(type: .camera, color: .orange, size: 13)
            } else if viewModel.statusMessage.contains("Listening") || viewModel.statusMessage.contains("Hearing") {
                ZeroLoseIcon(type: .mic, color: .red, size: 13)
                    .symbolEffect(.pulse)
            }

            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let commandErrorMessage {
                Text(commandErrorMessage)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            if !viewModel.currentModelDisplay.isEmpty {
                Text("\(activeProvider.displayName) · \(activeReasoningModel)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(4)
                    .lineLimit(1)
            }
        }
        .padding(.trailing, 4)
    }

    // MARK: - Scrollable Content

    @ViewBuilder
    private var scrollableContent: some View {
        GeometryReader { outerGeo in
            if viewModel.messages.isEmpty {
                VStack {
                    Spacer()
                    let stealthMode = UserDefaults.standard.bool(forKey: "stealthModeEnabled")
                    ZeroLoseIcon(
                        type: stealthMode ? .sparkles : .brain,
                        color: themeColor.opacity(0.35),
                        size: 56
                    )
                    .shadow(color: themeColor.opacity(0.12), radius: 10)
                    .symbolEffect(.pulse)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(viewModel.messages) { message in
                                messageRow(message)
                                    .id(message.id)
                                    .padding(.horizontal, 12)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                                .background(
                                    GeometryReader { markerGeo in
                                        Color.clear.preference(
                                            key: BottomMarkerYPreferenceKey.self,
                                            value: markerGeo.frame(in: .named("scroll")).minY
                                        )
                                    }
                                )
                        }
                        .padding(.vertical, 10)
                    }
                    .coordinateSpace(name: "scroll")
                    .onChange(of: viewModel.messages.count) {
                        // A new message arrived. Always return to the bottom so
                        // the user sees the fresh assistant reply, even if they
                        // previously scrolled up reading an older message. The
                        // down-arrow button still appears when they scroll away.
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        isNearBottom = true
                    }
                    .onChange(of: viewModel.messages.last?.text) {
                        // While a model streams, keep the caret pinned to the
                        // bottom unless the user has deliberately scrolled up.
                        if isNearBottom {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .onPreferenceChange(BottomMarkerYPreferenceKey.self) { y in
                        isNearBottom = y <= (outerGeo.size.height + 24)
                    }
                    .onAppear {
                        isNearBottom = true
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !isNearBottom {
                            scrollToBottomButton(proxy: proxy)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.15))
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.25), radius: 5, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .padding(12)
        .help("Aşağı kaydır")
    }

    // MARK: - Message Row

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        if message.isUser {
            userBubble(message)
        } else {
            aiBubble(message)
        }
    }

    @ViewBuilder
    private func userBubble(_ message: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Spacer(minLength: 50)

            VStack(alignment: .leading, spacing: 8) {
                if let imageData = message.imageData, let nsImage = NSImage(data: imageData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.glassStroke, lineWidth: 0.5)
                        )
                }

                if !message.text.hasPrefix("[Analyzing Image:") {
                    Text(verbatim: message.text)
                        .font(.system(size: fontSize, weight: .regular, design: fontDesign))
                        .foregroundStyle(Color.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .liquidGlassSurface(cornerRadius: 14)
            .textSelection(.enabled)

            ZeroLoseIcon(type: .person, color: Color.textSecondary, size: 14)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func aiBubble(_ message: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZeroLoseIcon(type: .brain, color: themeColor, size: 18)
                .padding(.top, 2)

            if message.type == .error {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                        Text("Error")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }

                    Text(verbatim: message.text)
                        .foregroundStyle(.red.opacity(0.9))
                        .font(.system(size: fontSize, design: .monospaced))

                    HStack {
                        Spacer(minLength: 0)
                        MessageCopyButton(text: message.text)
                    }
                }
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.red.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.red.opacity(0.25), lineWidth: 0.5)
                        )
                }

            } else if message.type == .thinking {
                if let thinking = message.thinking, !thinking.isEmpty {
                    MessageContent(text: message.text, isUser: false, thinking: thinking, isStreaming: viewModel.isBusy)
                        .equatable()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    ThinkingIndicator()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }

            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let toolRun = message.toolRun {
                        // Ajanın çalıştırdığı bir araç: görünür komut kartı göster.
                        MessagingToolRunCard(run: toolRun)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        MessageContent(text: message.text, isUser: false, thinking: message.thinking, isStreaming: viewModel.isBusy)
                            .equatable()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !message.text.isEmpty {
                        HStack(spacing: 8) {
                            if let badgeText = message.assistantBadgeText {
                                MessageBadge(text: badgeText)
                            }
                            if message.allowsAIRefinement {
                                MessageAIButton(disabled: viewModel.isBusy) {
                                    viewModel.refineAnswer(messageID: message.id)
                                }
                            }
                            MessageCopyButton(text: message.text)
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    // MARK: - Input Bar

    @ViewBuilder
    private var inputBar: some View {
        VStack(spacing: 8) {
            if showSlashCommands && !filteredSlashCommands.isEmpty {
                slashCommandOverlay
                    .animation(.spring(response: 0.28, dampingFraction: 0.78), value: showSlashCommands)
            }

            if let fileName = viewModel.attachedFileName {
                attachmentPreview(fileName: fileName)
            }

            mainInputRow
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isDropTargeted ? Color.cyan.opacity(0.18) : Color.glassFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isDropTargeted ? Color.cyan.opacity(0.6) : Color.glassStroke, lineWidth: isDropTargeted ? 1.5 : 0.8)
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers)
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        // Preferred path: Finder exposes the dropped file as a file URL.
        // `canLoadObject(ofClass: URL.self)` can return false for some Finder
        // drags, so we fall back to the conforming-type + raw-data path below.
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    viewModel.attachFile(from: url)
                }
            }
            return true
        }

        // Robust fallback: read the file URL out of the raw item payload. This
        // handles drags where Finder only publishes the file's data or a
        // conforming file-url item instead of a fully-formed URL object.
        let fileType = UTType.fileURL.identifier
        if provider.hasItemConformingToTypeIdentifier(fileType) {
            provider.loadItem(forTypeIdentifier: fileType, options: nil) { item, _ in
                let url: URL?
                if let droppedURL = item as? URL {
                    url = droppedURL
                } else if let data = item as? Data,
                          let fileURL = URL(dataRepresentation: data, relativeTo: nil) {
                    url = fileURL
                } else {
                    url = nil
                }
                guard let url else { return }
                Task { @MainActor in
                    viewModel.attachFile(from: url)
                }
            }
            return true
        }

        return false
    }

    @ViewBuilder
    private func attachmentPreview(fileName: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "paperclip")
                .font(.caption.weight(.medium))
                .foregroundStyle(.cyan)

            Text(fileName)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            Button(action: { viewModel.clearAttachment() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.cyan.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.cyan.opacity(0.3), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var mainInputRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Input line: camera + text field + mic/send.
            HStack(spacing: 6) {
            // Input Field
            TextField("", text: $inputText)
                .placeholder(when: inputText.isEmpty) {
                    Text("Bir şey sor...")
                        .foregroundStyle(Color.textSecondary)
                }
                .textFieldStyle(.plain)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.primary)
                .autocorrectionDisabled(true)
                .focused($isInputFocused)
                .onSubmit { handleInputSubmit() }
                .onMoveCommand { direction in moveSlashSelection(direction) }
                .onExitCommand { showSlashCommands = false }

            // Trailing Actions
            trailingActions
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                if #available(macOS 26.0, *) {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.regularMaterial)
                } else {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.zeroHeader)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.glassStroke, lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            .animation(.spring(response: 0.28, dampingFraction: 0.75), value: inputText.isEmpty)
            .animation(.spring(response: 0.28, dampingFraction: 0.75), value: viewModel.attachedFileData != nil)

            // Bottom control line: quick actions + model selector + approval +
            // context meter, all on one clean glass strip.
            inputControlStrip
        }
    }

    /// Compact control strip below the text field: provider/model picker,
    /// approval mode selector, and a real-time context-window usage meter.
    @ViewBuilder
    private var inputControlStrip: some View {
        HStack(spacing: 8) {
            // Quick actions (+)
            Menu {
                Button("Dosya Ekle (PDF, Resim)") { showFilePicker() }
                Divider()
                Toggle("Zorla Web Arama", isOn: $forceWebSearch)
                Divider()
                Button("Ekranı Analiz Et") { viewModel.analyzeScreen() }
            } label: {
                Image(systemName: forceWebSearch ? "globe.badge.chevron.backward" : "plus.circle")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(forceWebSearch ? .cyan : Color.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Circle())
            }
            .buttonStyle(.interactive)
            .help(forceWebSearch ? "Web Arama: ZORUNLU" : "Hızlı İşlemler")
            .pointerCursor()

            Divider().frame(height: 16).overlay(Color.primary.opacity(0.12))

            Menu {
                ForEach(LLMProvider.allCases, id: \.rawValue) { provider in
                    Button {
                        llmProviderRaw = provider.rawValue
                    } label: {
                        if provider == activeProvider {
                            Label("\(provider.displayName) (aktif)", systemImage: "checkmark")
                        } else {
                            Text(provider.displayName)
                        }
                    }

                    Menu {
                        ForEach(reasoningModelCandidates(for: provider), id: \.self) { model in
                            Button {
                                // Selecting a model from a provider submenu must
                                // also switch the active provider to that model's
                                // provider, otherwise the selection is silently
                                // ignored while the active provider differs.
                                llmProviderRaw = provider.rawValue
                                setReasoningModel(model, for: provider)
                            } label: {
                                if model == AIModelNames.reasoning(forProvider: provider) {
                                    Label(model, systemImage: "checkmark")
                                } else {
                                    Text(model)
                                }
                            }
                        }
                    } label: {
                        Text("\(provider.displayName) modeli")
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: activeProvider == .deepSeek || activeProvider == .openCodeZen || activeProvider == .openCodeGo ? "brain.head.profile" : "cpu")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(themeColor)
                    Text("\(activeProvider.displayName) · \(activeReasoningModel)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.glassStroke, lineWidth: 0.8))
            }
            .menuStyle(.borderlessButton)
            .layoutPriority(1)

            if !supportedReasoningEfforts.isEmpty {
                Menu {
                    ForEach(supportedReasoningEfforts, id: \.self) { effort in
                        Button {
                            setReasoningEffort(effort)
                        } label: {
                            if selectedReasoningEffort == effort {
                                Label("effort: \(effort)", systemImage: "checkmark")
                            } else {
                                Text("effort: \(effort)")
                            }
                        }
                    }
                } label: {
                    Text("effort: \(selectedReasoningEffort)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(themeColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Capsule())
                }
                .menuStyle(.borderlessButton)
            }

            Menu {
                Button("Onay İste") { setAuthorityMode(.manual) }
                Button("Oto Onay") { setAuthorityMode(.auto) }
                Button("Otonom") { setAuthorityMode(.autonomous) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: settingsViewModel.authorityMode == .autonomous ? "checkmark.shield.fill" : "checkmark.shield")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(approvalColor)
                    Text(approvalLabel)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.85))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.glassStroke, lineWidth: 0.8))
            }
            .menuStyle(.borderlessButton)

            Spacer(minLength: 0)

            contextMeter
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.glassFill.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.glassStroke, lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
    }

    private var approvalColor: Color {
        switch settingsViewModel.authorityMode {
        case .manual: return .secondary
        case .auto: return .green
        case .autonomous: return .orange
        case .fullAccess: return .orange
        }
    }

    private func setAuthorityMode(_ mode: AuthorityMode) {
        Task { @MainActor in
            try? await settingsViewModel.setAuthorityMode(mode)
        }
    }

    private func reasoningModelCandidates(for provider: LLMProvider) -> [String] {
        let cached = settingsViewModel.models(for: credentialProvider(for: provider))
        if !cached.isEmpty {
            return cached
        }

        // Before the live catalog is fetched (or when offline), show the curated
        // fallback so the picker is never empty. DeepSeek keeps its own set.
        switch provider {
        case .openCodeZen:
            return AIModelNames.openCodeZenCatalog
        case .openCodeGo:
            return AIModelNames.openCodeGoCatalog
        default:
            return [
                AIModelNames.reasoning(forProvider: provider),
                AIModelNames.fast(forProvider: provider),
                AIModelNames.coding(forProvider: provider)
            ]
        }
    }

    private func setReasoningModel(_ model: String, for provider: LLMProvider) {
        switch provider {
        case .openAI: customOpenAIReasoningModel = model
        case .deepSeek: customDeepSeekReasoningModel = model
        case .openCodeZen: customOpenCodeZenReasoningModel = model
        case .openCodeGo: customOpenCodeGoReasoningModel = model
        case .ollama: customOllamaReasoningModel = model
        }
    }

    @ViewBuilder
    private var contextMeter: some View {
        let usage = viewModel.contextUsage
        VStack(alignment: .trailing, spacing: 2) {
            Text("Konteks %\(Int((usage.fraction * 100).rounded()))")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(usage.fraction > 0.85 ? .red : .secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(usage.fraction > 0.85 ? Color.red : (usage.fraction > 0.6 ? Color.orange : themeColor))
                        .frame(width: geo.size.width * usage.fraction)
                }
            }
            .frame(width: 72, height: 4)
        }
        .help("Kullanılan tahmini bağlam")
    }

    @ViewBuilder
    private var trailingActions: some View {
        HStack(spacing: 2) {
            Button(action: { viewModel.testComputerUseSnapshot() }) {
                Image(systemName: "cursorarrow.click.2")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.interactive)
            .help("Computer Use: Ön plandaki uygulamayı oku")
            .disabled(viewModel.isBusy)
            .pointerCursor()

            Button(action: { viewModel.verifyComputerUseEndToEnd() }) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.interactive)
            .help("Computer Use: Uçtan uca doğrula (izin + ağaç oku)")
            .disabled(viewModel.isBusy)
            .pointerCursor()

            Button(action: { viewModel.analyzeScreen() }) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.interactive)
            .help("Analyze Screen")
            .disabled(viewModel.isBusy)
            .pointerCursor()

            if viewModel.isBusy {
                Button(action: { withAnimation { viewModel.stopResponse() } }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.red)
                        .clipShape(Circle())
                        .shadow(color: .red.opacity(0.4), radius: 5)
                }
                .buttonStyle(.interactive)
                .pointerCursor()
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .help("Stop AI Response")

            } else if inputText.isEmpty && viewModel.attachedFileData == nil {
                HStack(spacing: 10) {
                    Button(action: { viewModel.toggleListening() }) {
                        Image(systemName: "mic")
                            .font(.system(size: 17, weight: viewModel.isListeningActive ? .semibold : .light))
                            .foregroundStyle(viewModel.isListeningActive ? .red : Color.textSecondary)
                            .frame(width: 34, height: 34)
                            .background(viewModel.isListeningActive ? Color.red.opacity(0.12) : Color.clear)
                            .clipShape(Circle())
                            .symbolEffect(.pulse, isActive: viewModel.isListeningActive)
                    }
                    .buttonStyle(.interactive)
                    .pointerCursor()
                    .help("Transcription Mode")
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: viewModel.isListeningActive)

                    if viewModel.isListeningActive && !viewModel.liveVoicePreview.isEmpty {
                        Text(viewModel.liveVoicePreview)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .transition(.opacity)
                    }
                }

            } else {
                Button(action: { submitQuery() }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(themeColor)
                        .clipShape(Circle())
                        .shadow(color: themeColor.opacity(0.4), radius: 6)
                }
                .buttonStyle(.interactive)
                .pointerCursor()
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.5).combined(with: .opacity),
                    removal: .scale(scale: 0.5).combined(with: .opacity)
                ))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.isBusy)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: inputText.isEmpty)
    }

    // MARK: - Slash Command Logic

    private func detectSlashCommand(_ text: String) {
        guard let slashToken = extractSlashToken(from: text) else {
            showSlashCommands = false
            slashCommandFilter = ""
            selectedSlashIndex = 0
            return
        }
        showSlashCommands = true
        slashCommandFilter = slashToken

        let matchCount = matchingSlashCommands(for: slashToken).count
        if matchCount == 0 {
            selectedSlashIndex = 0
        } else {
            selectedSlashIndex = min(selectedSlashIndex, matchCount - 1)
        }
    }

    private func applySlashCommand(_ cmd: SlashCommand) {
        suppressNextSlashDetection = true
        inputText = cmd.command + " "
        showSlashCommands = false
        isInputFocused = true
    }

    private func scrollSelectedSlashCommand(into proxy: ScrollViewProxy, animated: Bool) {
        guard showSlashCommands,
              !filteredSlashCommands.isEmpty,
              filteredSlashCommands.indices.contains(selectedSlashIndex) else { return }

        let selectedID = filteredSlashCommands[selectedSlashIndex].id
        if animated {
            withAnimation(.easeInOut(duration: 0.12)) { proxy.scrollTo(selectedID, anchor: .center) }
        } else {
            proxy.scrollTo(selectedID, anchor: .center)
        }
    }

    private func installSlashKeyMonitor() {
        guard slashKeyMonitor == nil else { return }
        slashKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard showSlashCommands, !filteredSlashCommands.isEmpty, isInputFocused else { return event }
            switch event.keyCode {
            case 125: moveSlashSelection(.down); return nil
            case 126: moveSlashSelection(.up); return nil
            case 36, 76:
                let idx = min(max(selectedSlashIndex, 0), filteredSlashCommands.count - 1)
                applySlashCommand(filteredSlashCommands[idx])
                return nil
            case 53: showSlashCommands = false; return nil
            default: return event
            }
        }
    }

    private func removeSlashKeyMonitor() {
        if let monitor = slashKeyMonitor {
            NSEvent.removeMonitor(monitor)
            slashKeyMonitor = nil
        }
    }

    // MARK: - Helper Methods

    private func dismissInterviewVault() {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { isInterviewVaultPresented = false }
    }

    private func handleInputSubmit() {
        if showSlashCommands, !filteredSlashCommands.isEmpty {
            let idx = min(max(selectedSlashIndex, 0), filteredSlashCommands.count - 1)
            applySlashCommand(filteredSlashCommands[idx])
            return
        }
        submitQuery()
    }

    private func moveSlashSelection(_ direction: MoveCommandDirection) {
        guard showSlashCommands, !filteredSlashCommands.isEmpty else { return }
        switch direction {
        case .down: selectedSlashIndex = (selectedSlashIndex + 1) % filteredSlashCommands.count
        case .up:   selectedSlashIndex = (selectedSlashIndex - 1 + filteredSlashCommands.count) % filteredSlashCommands.count
        default: break
        }
    }

    private func matchingSlashCommands(for token: String) -> [SlashCommand] {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return SlashCommandRegistry.commands }
        if normalized == "/" { return SlashCommandRegistry.commands }
        return SlashCommandRegistry.commands.filter { $0.command.lowercased().hasPrefix(normalized) }
    }

    private func extractSlashToken(from text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let token = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard token.hasPrefix("/") else { return nil }
        return token
    }

    private func submitQuery() {
        guard !inputText.isEmpty || viewModel.attachedFileData != nil else { return }
        let query = inputText
        inputText = ""
        let searchMode: WebSearchMode = forceWebSearch ? .forceOn : .automatic
        // A new user query should always pull the view back to the newest
        // message, so a prior manual scroll-up cannot permanently disable
        // auto-scroll for the next reply.
        isNearBottom = true

        if viewModel.attachedFileData != nil || forceWebSearch {
            // Attachment/forced-search presentation remains on the temporary
            // compatibility bridge until the corresponding V2 commands land.
            viewModel.submitQuery(query, webSearchMode: searchMode)
        } else {
            Task { @MainActor in
                do {
                    try await chatViewModel.submit(query)
                    commandErrorMessage = nil
                } catch {
                    commandErrorMessage = "Command failed: \(error.localizedDescription)"
                    if inputText.isEmpty {
                        inputText = query
                    }
                }
            }
        }
    }

    private func showFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .png, .jpeg, .pdf]
        panel.message = "Select an image or PDF to analyze"
        panel.prompt = "Attach"
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.attachFile(from: url)
        }
    }
}

// MARK: - Preference Key

struct BottomMarkerYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

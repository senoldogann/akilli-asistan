import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @Bindable var viewModel: GhostViewModel
    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool
    @State private var isNearBottom: Bool = true
    @State private var isHistoryPresented: Bool = false
    @State private var isInterviewVaultPresented: Bool = false
    @State private var isMockInterviewPresented: Bool = false

    // User Settings
    @AppStorage("fontSize") private var fontSize: Double = 14.0
    @AppStorage("fontDesign") private var fontDesignStr: String = "monospaced"
    @AppStorage("selectedThemeName") private var selectedTheme: String = "Red"
    @AppStorage("forceWebSearch") private var forceWebSearch: Bool = false
    @AppStorage("windowOpacity") private var windowOpacity: Double = 1.0

    var fontDesign: Font.Design {
        switch fontDesignStr {
        case "serif":   return .serif
        case "rounded": return .rounded
        case "default": return .default
        default:        return .monospaced
        }
    }

    private var themeColor: Color { .brandPrimary }

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
            .onAppear { installSlashKeyMonitor() }
            .onDisappear { removeSlashKeyMonitor() }
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
            if let activeAction = viewModel.zeroOperator.activeAction {
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
                ZeroLoseIcon(type: .sparkles, color: viewModel.isBusy ? .cyan : themeColor, size: 22)
                    .symbolEffect(.pulse, isActive: viewModel.isBusy)

                Text("ZERO LOSE")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
                    .tracking(1.2)
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
                        isNearBottom = true
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: viewModel.messages.last?.text) {
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
                }
            }
        }
        .frame(maxHeight: .infinity)
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
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.glassFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.glassStroke, lineWidth: 0.5)
                    )
            }
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
                ThinkingIndicator()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)

            } else {
                VStack(alignment: .leading, spacing: 6) {
                    MessageContent(text: message.text, isUser: false)
                        .equatable()
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !message.text.isEmpty {
                        HStack(spacing: 8) {
                            if let badgeText = message.assistantBadgeText {
                                MessageBadge(text: badgeText)
                            }
                            if message.allowsAIRefinement {
                                MessageAIButton(disabled: viewModel.isBusy) {
                                    viewModel.refineAnswerWithAI(messageID: message.id)
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
        HStack(spacing: 6) {
            // Quick actions (+)
            Menu {
                Button("Attach File (PDF, Image)") { showFilePicker() }
                Divider()
                Toggle("Force Web Search", isOn: $forceWebSearch)
            } label: {
                Image(systemName: forceWebSearch ? "globe.badge.chevron.backward" : "plus.circle")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(forceWebSearch ? .cyan : Color.textSecondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.interactive)
            .help(forceWebSearch ? "Web Search: FORCED ON" : "Quick Actions")
            .pointerCursor()

            // Input Field
            TextField("", text: $inputText)
                .placeholder(when: inputText.isEmpty) {
                    Text("Ask anything...")
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
        .padding(.horizontal, 12)
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
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: inputText.isEmpty)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: viewModel.attachedFileData != nil)
    }

    @ViewBuilder
    private var trailingActions: some View {
        HStack(spacing: 2) {
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
        viewModel.askQuestion(query, webSearchMode: searchMode)
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

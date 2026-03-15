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
    
    // User Settings
    @AppStorage("fontSize") private var fontSize: Double = 14.0
    @AppStorage("fontDesign") private var fontDesignStr: String = "monospaced"
    @AppStorage("selectedThemeName") private var selectedTheme: String = "Red"
    @AppStorage("forceWebSearch") private var forceWebSearch: Bool = false
    
    // Helper for Font Design
    var fontDesign: Font.Design {
        switch fontDesignStr {
        case "serif": return .serif
        case "rounded": return .rounded
        case "default": return .default
        default: return .monospaced
        }
    }
    
    // Helper to get dynamic color
    private var themeColor: Color {
        switch selectedTheme {
        case "Red": return Color(red: 242/255, green: 78/255, blue: 78/255)
        case "Orange": return Color.orange
        case "Blue": return Color.blue
        case "Purple": return Color.purple
        case "Green": return Color.green
        case "Graphite": return Color(white: 0.3)
        default: return Color(red: 242/255, green: 78/255, blue: 78/255)
        }
    }
    
    // Slash Command State
    @State private var showSlashCommands: Bool = false
    @State private var slashCommandFilter: String = ""
    @State private var selectedSlashIndex: Int = 0
    @State private var suppressNextSlashDetection: Bool = false
    @State private var slashKeyMonitor: Any?
    
    // Filtered Commands
    var filteredSlashCommands: [SlashCommand] {
        matchingSlashCommands(for: slashCommandFilter)
    }
    
    var body: some View {
        mainLayout
            .overlay(borderOverlay)
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
            }
            .onDisappear {
                removeSlashKeyMonitor()
            }
    }
    
    // MARK: - Layout Components
    
    private var mainLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerBar
            
            Divider()
                .background(Color.white.opacity(0.15))
            
            scrollableContent

            inputBar
        }
        .padding()
        .padding()
        .background(Color.zeroBackground)
        .cornerRadius(16)
    }
    
    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(Color.white.opacity(0.1), lineWidth: 1)
    }

    @ViewBuilder
    private var slashCommandOverlay: some View {
        if showSlashCommands && !filteredSlashCommands.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Slash Actions")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filteredSlashCommands.enumerated()), id: \.element.id) { index, cmd in
                                Button(action: {
                                    applySlashCommand(cmd)
                                }) {
                                    HStack {
                                        Text(cmd.command)
                                            .font(.system(.subheadline, design: .monospaced))
                                            .fontWeight(.bold)
                                            .foregroundColor(.brandPrimary)
                                        
                                        Text(cmd.description)
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                            .lineLimit(1)
                                        
                                        Spacer()
                                        
                                        Text(cmd.category)
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.white.opacity(0.1))
                                            .cornerRadius(4)
                                            .foregroundColor(.white.opacity(0.7))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(index == selectedSlashIndex ? Color.brandPrimary.opacity(0.2) : Color.clear)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.interactive)
                                .id(cmd.id)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                    .onAppear {
                        scrollSelectedSlashCommand(into: proxy, animated: false)
                    }
                    .onChange(of: selectedSlashIndex) { _, _ in
                        scrollSelectedSlashCommand(into: proxy, animated: true)
                    }
                    .onChange(of: slashCommandFilter) { _, _ in
                        scrollSelectedSlashCommand(into: proxy, animated: false)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.92))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.2), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
    
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
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture { dismissInterviewVault() }
                    
                    InterviewVaultView(isPresented: $isInterviewVaultPresented) {
                        viewModel.warmUpInterviewContext()
                    }
                    .shadow(radius: 30)
                }
                .transition(.opacity)
                .zIndex(100)
            }

        }
    }
    
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
              filteredSlashCommands.indices.contains(selectedSlashIndex) else {
            return
        }

        let selectedID = filteredSlashCommands[selectedSlashIndex].id
        if animated {
            withAnimation(.easeInOut(duration: 0.12)) {
                proxy.scrollTo(selectedID, anchor: .center)
            }
        } else {
            proxy.scrollTo(selectedID, anchor: .center)
        }
    }

    private func installSlashKeyMonitor() {
        guard slashKeyMonitor == nil else { return }

        slashKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard showSlashCommands, !filteredSlashCommands.isEmpty, isInputFocused else {
                return event
            }

            switch event.keyCode {
            case 125: // Down arrow
                moveSlashSelection(.down)
                return nil
            case 126: // Up arrow
                moveSlashSelection(.up)
                return nil
            case 36, 76: // Return / Numpad Enter
                let clampedIndex = min(max(selectedSlashIndex, 0), filteredSlashCommands.count - 1)
                applySlashCommand(filteredSlashCommands[clampedIndex])
                return nil
            case 53: // Esc
                showSlashCommands = false
                return nil
            default:
                return event
            }
        }
    }

    private func removeSlashKeyMonitor() {
        if let monitor = slashKeyMonitor {
            NSEvent.removeMonitor(monitor)
            slashKeyMonitor = nil
        }
    }
    
    private func dismissInterviewVault() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isInterviewVaultPresented = false
        }
    }
    
    // MARK: - Header Bar
    @ViewBuilder
    private var headerBar: some View {
        HStack {
            ZeroLoseIcon(type: .sparkles, color: viewModel.isBusy ? .cyan : .brandPrimary, size: 28)
            
            Text("ZERO LOSE")
                .font(.system(.headline, design: .rounded))
                .foregroundColor(.white)
            
            Spacer()
            
            // Status with SVG Icon
            statusIndicator
            
            // Clipboard Button
            Button(action: { viewModel.toggleClipboard() }) {
                ZeroLoseIcon(type: .clipboard, color: viewModel.isClipboardActive ? .green : .brandPrimary, size: 18)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.interactive)
            .pointerCursor()
            .help("Toggle Clipboard Auto-Answer")
            
            // Clear History Button
            Button(action: { withAnimation { viewModel.clearHistory() } }) {
                ZeroLoseIcon(type: .trash, color: themeColor.opacity(0.8), size: 20)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.interactive)
            .pointerCursor()
            .help("Clear Chat History")

            // Teleprompter Button **(Fixed: Always Theme Colored)**
            Button(action: { WindowManager.shared.toggleTeleprompterWindow() }) {
                ZeroLoseIcon(type: .textbubble, color: themeColor.opacity(0.8), size: 18)
                    .foregroundColor(themeColor) // Force color update
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.interactive)
            .pointerCursor()
            .help("Interview Notes")
            
            // Interview Prep Vault Button
            Button(action: { 
                withAnimation { isInterviewVaultPresented = true }
            }) {
                ZeroLoseIcon(type: .book, color: themeColor.opacity(0.7), size: 18)
                    .foregroundColor(themeColor)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.interactive)
            .pointerCursor()
            .help("Interview Prep Vault")

            // Settings Button
            Button(action: { WindowManager.shared.toggleSettingsWindow() }) {
                ZeroLoseIcon(type: .gear, color: .brandPrimary, size: 20)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.interactive)
            .pointerCursor()
            .help("Settings")
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 5)
    }
    
    // MARK: - Status Indicator
    private var statusIndicator: some View {
        HStack(spacing: 8) {
            if viewModel.isIndexing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.brandPrimary)
            }
            
            if viewModel.statusMessage.contains("Thinking") || viewModel.statusMessage.contains("Searching") {
                ThinkingIndicator() // New Animated View
            } else {
                // Standard Status
                if viewModel.statusMessage.contains("Capturing") || viewModel.statusMessage.contains("Analyzing") {
                    ZeroLoseIcon(type: .camera, color: .orange, size: 14)
                } else if viewModel.statusMessage.contains("Listening") || viewModel.statusMessage.contains("Hearing") {
                    ZeroLoseIcon(type: .mic, color: .red, size: 14)
                }
                
                Text(viewModel.statusMessage)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.gray)
            }
        }
    }
    
    // MARK: - Scrollable Content
    @ViewBuilder
    private var scrollableContent: some View {
        GeometryReader { outerGeo in
            ScrollViewReader { proxy in
                ScrollView {
                    // Use LazyVStack for better performance with long histories
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(viewModel.messages) { message in
                            messageRow(message)
                                .id(message.id) // Explicit ID for better reconciliation
                        }
                        
                        // Bottom marker for autoscrolling
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
                    .padding(.vertical, 8)
                }
                .coordinateSpace(name: "scroll")
                .onChange(of: viewModel.messages.count) {
                    if isNearBottom {
                        // Use a spring animation but only when new messages are added
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: viewModel.messages.last?.text) {
                     if isNearBottom {
                         // Non-animated scroll for streaming text updates to avoid high CPU/GPU load
                         proxy.scrollTo("bottom", anchor: .bottom)
                     }
                }
                .onPreferenceChange(BottomMarkerYPreferenceKey.self) { bottomMarkerY in
                    isNearBottom = bottomMarkerY <= (outerGeo.size.height + 24)
                }
                .onAppear {
                    isNearBottom = true
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        if message.isUser {
            // User Question Bubble
            HStack(alignment: .top, spacing: 12) {
                ZeroLoseIcon(type: .person, color: .white.opacity(0.7), size: 16)
                    .padding(.top, 4)
                
                VStack(alignment: .leading, spacing: 8) {
                    if let imageData = message.imageData,
                       let nsImage = NSImage(data: imageData) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 300)
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2), lineWidth: 1))
                    }
                    
                    if !message.text.hasPrefix("[Analyzing Image:") {
                        Text(verbatim: message.text)
                            .font(.system(size: fontSize, weight: .regular, design: fontDesign))
                            .foregroundColor(.white.opacity(0.95))
                            .multilineTextAlignment(.leading)
                    }

                    if !message.text.isEmpty {
                        HStack {
                            Spacer(minLength: 0)
                            MessageCopyButton(text: message.text)
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            // AI Answer Bubble
            HStack(alignment: .top, spacing: 12) {
                ZeroLoseIcon(type: .brain, color: .brandPrimary, size: 20)
                    .padding(.top, 2)
                
                if message.type == .error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: message.text)
                            .foregroundColor(.red)
                            .font(.system(size: fontSize, design: .monospaced))

                        HStack {
                            Spacer(minLength: 0)
                            MessageCopyButton(text: message.text)
                        }
                    }
                } else if message.type == .thinking {
                    ThinkingIndicator()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
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
                                Spacer(minLength: 0)
                                MessageCopyButton(text: message.text)
                            }
                        }

                        MessageContent(text: message.text, isUser: false)
                            .equatable()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
    
    // MARK: - Input Bar
    @ViewBuilder
    private var inputBar: some View {
        VStack(spacing: 6) {
            if showSlashCommands && !filteredSlashCommands.isEmpty {
                slashCommandOverlay
            }
            
            // Attachment Preview (if file attached)
            if let fileName = viewModel.attachedFileName {
                attachmentPreview(fileName: fileName)
            }
            
            // Main Input Row
            mainInputRow
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.zeroHeader)
        .cornerRadius(30)
        .overlay(
            RoundedRectangle(cornerRadius: 30)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: inputText.isEmpty)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.attachedFileData != nil)
        .padding(.bottom, 12)
    }
    
    @ViewBuilder
    private func attachmentPreview(fileName: String) -> some View {
        HStack {
            ZeroLoseIcon(type: .clipboard, color: .cyan, size: 14)
            Text(fileName)
                .font(.system(.caption, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
            Spacer()
            Button(action: { viewModel.clearAttachment() }) {
                ZeroLoseIcon(type: .plus, color: .white.opacity(0.5), size: 12)
                    .rotationEffect(.degrees(45))
            }
            .buttonStyle(.interactive)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.cyan.opacity(0.15))
        .cornerRadius(16)
    }
    
    @ViewBuilder
    private var mainInputRow: some View {
        HStack(spacing: 8) {
            // Leading: Quick actions (+)
            Menu {
                Button("Attach File (PDF, Image)") {
                    showFilePicker()
                }
                Divider()
                Toggle("Force Web Search", isOn: $forceWebSearch)
            } label: {
                ZeroLoseIcon(type: .plus, color: forceWebSearch ? .cyan : .white.opacity(0.7), size: 22)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.interactive)
            .help(forceWebSearch ? "Quick Actions • Web Search: ON" : "Quick Actions • Web Search: AUTO")
            .pointerCursor()
            
            // Middle: Input Field
            TextField("", text: $inputText)
                .placeholder(when: inputText.isEmpty) {
                    Text("Ask anything...")
                        .foregroundColor(.white.opacity(0.5)) // Slightly brighter
                }
                .textFieldStyle(.plain)
                .font(.system(.body, design: .rounded))
                .foregroundColor(.white)
                .autocorrectionDisabled(true)
                .focused($isInputFocused)
                .onSubmit { handleInputSubmit() }
                .onMoveCommand { direction in
                    moveSlashSelection(direction)
                }
                .onExitCommand {
                    showSlashCommands = false
                }
            
            // Trailing: Action Buttons
            trailingActions
        }
    }
    
    @ViewBuilder
    private var trailingActions: some View {
        HStack(alignment: .center, spacing: 2) {
            // Camera/Screen Analyze Button
            Button(action: { viewModel.analyzeScreen() }) {
                ZeroLoseIcon(type: .camera, color: .white.opacity(0.7), size: 18)
                    .frame(width: 36, height: 36)
                    .offset(y: 4.5) // Fix visual alignment (User reported it was still too high)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.interactive)
            .help("Analyze Screen")
            .disabled(viewModel.isBusy)
            .pointerCursor()
            
            if viewModel.isBusy {
                // STOP Button - Only visible when AI is processing
                Button(action: { withAnimation { viewModel.stopResponse() } }) {
                    ZeroLoseIcon(type: .xmark, color: .white, size: 14)
                        .frame(width: 32, height: 32)
                        .background(Color.red)
                        .clipShape(Circle())
                        .shadow(color: .red.opacity(0.3), radius: 4)
                }
                .buttonStyle(.interactive)
                .pointerCursor()
                .transition(.scale.combined(with: .opacity))
                .help("Stop AI Response")
            } else {
                if inputText.isEmpty && viewModel.attachedFileData == nil {
                    // Mic Button
                    Button(action: { viewModel.toggleListening() }) {
                        ZeroLoseIcon(
                            type: .mic,
                            color: viewModel.isListeningActive ? .red : .white.opacity(0.7),
                            size: 18
                        )
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.interactive)
                    .pointerCursor()
                    .help("Transcription Mode")
    
                    // Waveform Indicator
                    Button(action: {}) {
                        ZeroLoseIcon(
                            type: .waveform,
                            color: viewModel.isListeningActive ? .cyan : .white.opacity(0.35),
                            size: 18
                        )
                        .frame(width: 36, height: 36)
                        .background(viewModel.isListeningActive ? Color.cyan.opacity(0.2) : Color.clear)
                        .clipShape(Circle())
                    }
                    .buttonStyle(.interactive)
                    .help("Processing Status")
                } else {
                    // Send Button - smaller and theme-colored
                    Button(action: { submitQuery() }) {
                        ZeroLoseIcon(type: .paperplane, color: .white, size: 14)
                            .frame(width: 32, height: 32)
                            .background(Color.brandPrimary)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.interactive)
                    .pointerCursor()
                    .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .opacity))
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func handleInputSubmit() {
        if showSlashCommands, !filteredSlashCommands.isEmpty {
            let clampedIndex = min(max(selectedSlashIndex, 0), filteredSlashCommands.count - 1)
            applySlashCommand(filteredSlashCommands[clampedIndex])
            return
        }
        
        submitQuery()
    }
    
    private func moveSlashSelection(_ direction: MoveCommandDirection) {
        guard showSlashCommands, !filteredSlashCommands.isEmpty else { return }
        
        switch direction {
        case .down:
            selectedSlashIndex = (selectedSlashIndex + 1) % filteredSlashCommands.count
        case .up:
            selectedSlashIndex = (selectedSlashIndex - 1 + filteredSlashCommands.count) % filteredSlashCommands.count
        default:
            break
        }
    }
    
    private func matchingSlashCommands(for token: String) -> [SlashCommand] {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return SlashCommandRegistry.commands }
        
        if normalized == "/" {
            return SlashCommandRegistry.commands
        }
        
        return SlashCommandRegistry.commands.filter { command in
            let cmd = command.command.lowercased()
            return cmd.hasPrefix(normalized)
        }
    }
    
    private func extractSlashToken(from text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        
        let token = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard token.hasPrefix("/") else { return nil }
        return token
    }
    
    private func submitQuery() {
        guard !inputText.isEmpty || viewModel.attachedFileData != nil else { return }
        
        // Clear immediately for responsiveness
        let query = inputText
        inputText = ""
        
        // Execute
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

// PreferenceKey to track bottom marker position relative to viewport.
struct BottomMarkerYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

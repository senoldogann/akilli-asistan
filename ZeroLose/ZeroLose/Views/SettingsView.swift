import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import os

struct SettingsView: View {
    @Binding var isPresented: Bool
    
    @AppStorage("fontSize") private var fontSize: Double = 14.0
    @AppStorage("fontDesign") private var fontDesignObj: String = "monospaced"
    @AppStorage("windowWidth") private var windowWidth: Double = 450.0
    @AppStorage("windowHeight") private var windowHeight: Double = 400.0
    @AppStorage("windowOpacity") private var windowOpacity: Double = 1.0
    @AppStorage("autoAnalyze") private var autoAnalyze: Bool = true
    @AppStorage("useExternalAudio") private var useExternalAudio: Bool = true
    @AppStorage("stealthModeEnabled") private var stealthMode: Bool = false
    @AppStorage("audioLanguage") private var audioLanguage: String = "en"
    @AppStorage("userPersonaContext") private var userPersonaContext: String = ""
    @AppStorage("activeJobDescription") private var activeJobDescription: String = ""
    @AppStorage("teleprompterText") private var teleprompterText: String = ""
    @AppStorage("selectedThemeName") private var selectedTheme: String = "Red"
    
    // API Keys - Settings'ten yönetim için
    @State private var openAIKey: String = ""
    @State private var ollamaKey: String = ""
    @State private var groqKey: String = ""
    @State private var tavilyKey: String = ""
    @State private var showKeys: Bool = false
    @State private var memoryChunkCount: Int = 0
    @State private var isClearingMemory: Bool = false
    @State private var memoryStatus: String = ""
    
    @ObservedObject private var hotkeyManager = HotkeyManager.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.zerolose", category: "SettingsView")
    
    var body: some View {
        ZStack {
            // Background matching App Theme
            Color.zeroBackground
                .ignoresSafeArea()
            
            // Border
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
            
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    settingsHeader
                    
                    // Sections
                    hotkeyStatusSection
                    apiKeysSection
                    appearanceSection
                    typographySection
                    personaSection
                    activeRoleSection
                    storedContextSection
                    memorySection
                    windowSection
                    featuresSection
                    
                    Spacer(minLength: 20)
                }
                .padding(24)
            }
        }
        .frame(width: 380, height: 500)
        .cornerRadius(16)
        .shadow(radius: 20)
        .preferredColorScheme(.dark)
        .onAppear {
            refreshMemoryState()
            WindowManager.shared.updateWindowOpacity(windowOpacity)
        }
        .onChange(of: windowWidth) { _, newValue in
            WindowManager.shared.updateMainWindowSize(width: newValue, height: windowHeight)
        }
        .onChange(of: windowHeight) { _, newValue in
            WindowManager.shared.updateMainWindowSize(width: windowWidth, height: newValue)
        }
        .onChange(of: windowOpacity) { _, newValue in
            WindowManager.shared.updateWindowOpacity(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .vectorStoreDidChange)) { _ in
            refreshMemoryState()
        }
    }
    
    // MARK: - Header
    private var settingsHeader: some View {
        HStack {
            ZeroLoseIcon(type: .gear, color: .brandPrimary, size: 24)
            Text("Settings")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            
            Spacer()
            
            // Close Button
            Button(action: { withAnimation { isPresented = false } }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.interactive)
            .pointerCursor()
        }
        .padding(.bottom, 8)
    }
    
    // MARK: - Typography Section
    private var typographySection: some View {
        SettingsSection(title: "Typography", icon: .sparkles) {
            VStack(spacing: 16) {
                // Font Size
                SettingsRow(label: "Font Size", value: "\(Int(fontSize))pt") {
                    Slider(value: $fontSize, in: 10...32, step: 1)
                        .tint(.brandPrimary)
                }
                
                // Font Design
                HStack {
                    Text("Font Style")
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    Picker("", selection: $fontDesignObj) {
                        Text("Mono").tag("monospaced")
                        Text("System").tag("default")
                        Text("Serif").tag("serif")
                        Text("Rounded").tag("rounded")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 120) // Fixed width for dropdown
                    .tint(.brandPrimary)
                }
            }
        }
    }
    
    // MARK: - Persona Section
    private var personaSection: some View {
        SettingsSection(title: "Persona & Context", icon: .brain) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Paste your CV, Tech Stack, or Experience Summary here. AI will personalize answers based on this.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(2)
                    
                    Spacer()
                    
                    // Import PDF/Text Button
                    Button(action: importPersonaFile) {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.down")
                            Text("Import PDF/TXT")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.interactive)
                    .pointerCursor()
                }
                
                TextEditor(text: $userPersonaContext)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.9))
                    .scrollContentBackground(.hidden)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(8)
                    .frame(height: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            }
        }
    }

    private var activeRoleSection: some View {
        let preview = ActiveRoleProfileService.previewSummary(for: activeJobDescription)

        return SettingsSection(title: "Active Interview Role", icon: .book) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Paste the current job description here. We will use it as active company/role grounding during interview answers.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(2)

                    Spacer()

                    Button(action: importActiveRoleFile) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text.fill")
                            Text("Import JD")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.interactive)
                    .pointerCursor()
                }

                TextEditor(text: $activeJobDescription)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.9))
                    .scrollContentBackground(.hidden)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(8)
                    .frame(height: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 6) {
                    Text("Parsed Role Pack")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.orange.opacity(0.9))

                    Text(preview)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.orange.opacity(0.12), lineWidth: 1)
                        )
                }
            }
        }
    }
    
    // MARK: - Memory Section
    private var memorySection: some View {
        SettingsSection(title: "Memory (RAG)", icon: .brain) {
            VStack(alignment: .leading, spacing: 12) {
                Text("AI remembers PDFs and conversations stored in the local vector database.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Indexed Documents")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                        Text("PDFs, chat history chunks")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    
                    Spacer()
                    
                    // Document count badge
                    Text("\(memoryChunkCount) chunks")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(memoryChunkCount > 0 ? .green : .orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background((memoryChunkCount > 0 ? Color.green : Color.orange).opacity(0.2))
                        .cornerRadius(6)
                }
                
                if !memoryStatus.isEmpty {
                    Text(memoryStatus)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                }
                
                Divider()
                    .background(Color.white.opacity(0.1))
                
                // Clear Memory Button
                Button(action: clearMemory) {
                    HStack {
                        Image(systemName: "trash")
                        Text(isClearingMemory ? "Clearing..." : "Clear All Memory")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.red.opacity(0.8))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.red.opacity(0.3), lineWidth: 1)
                    )
                }
                .disabled(isClearingMemory)
                .buttonStyle(.interactive)
                .pointerCursor()
            }
        }
    }

    private var storedContextSection: some View {
        SettingsSection(title: "Stored Context", icon: .brain) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Persona, active role text, and interview notes are stored locally and survive restarts.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    contextClearButton(
                        title: "Clear Persona",
                        isEnabled: !userPersonaContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        action: { userPersonaContext = "" }
                    )
                    contextClearButton(
                        title: "Clear Role",
                        isEnabled: !activeJobDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        action: { activeJobDescription = "" }
                    )
                }

                contextClearButton(
                    title: "Clear Interview Notes",
                    isEnabled: !teleprompterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: { teleprompterText = "" }
                )
            }
        }
    }

    private func contextClearButton(
        title: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isEnabled ? .orange.opacity(0.9) : .white.opacity(0.35))
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(isEnabled ? Color.orange.opacity(0.08) : Color.white.opacity(0.04))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isEnabled ? Color.orange.opacity(0.28) : Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .disabled(!isEnabled)
        .buttonStyle(.interactive)
        .pointerCursor()
    }
    
    private func clearMemory() {
        guard !isClearingMemory else { return }
        isClearingMemory = true
        memoryStatus = "Clearing vector database and session context..."
        
        Task {
            do {
                try await DependencyContainer.shared.vectorStore.deleteAll()
                await DependencyContainer.shared.chatHistoryService.startNewSession()
                DependencyContainer.shared.intelligenceService.clearHistory()
                
                let countAfterClear = try await DependencyContainer.shared.vectorStore.countEmbeddings()
                
                await MainActor.run {
                    memoryChunkCount = countAfterClear
                    memoryStatus = "Memory cleared successfully."
                    isClearingMemory = false
                }
            } catch {
                logger.error("Failed to clear vector store: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    memoryStatus = "Failed to clear memory: \(error.localizedDescription)"
                    isClearingMemory = false
                }
            }
        }
    }

    // MARK: - Window Section
    private var windowSection: some View {
        SettingsSection(title: "Window", icon: .gear) {
            VStack(spacing: 16) {
                SettingsRow(label: "Width", value: "\(Int(windowWidth))px") {
                    Slider(value: $windowWidth, in: 350...800, step: 10)
                        .tint(.brandPrimary)
                }
                
                SettingsRow(label: "Height", value: "\(Int(windowHeight))px") {
                    Slider(value: $windowHeight, in: 300...1000, step: 10)
                        .tint(.brandPrimary)
                }
                
                SettingsRow(label: "Opacity", value: "\(Int(windowOpacity * 100))%") {
                    Slider(value: $windowOpacity, in: 0.35...1.0, step: 0.01)
                        .tint(.brandPrimary)
                }
                
                Button(action: {
                    withAnimation(.spring(response: 0.3)) {
                        windowWidth = 450
                        windowHeight = 400
                        windowOpacity = 1.0
                    }
                }) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Restore Defaults")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
                }
                .buttonStyle(.interactive)
                .pointerCursor()
            }
        }
    }
    
    // MARK: - Features Section
    private var featuresSection: some View {
        SettingsSection(title: "Features", icon: .eye) {
            VStack(spacing: 16) {
                // Auto-Analyze Toggle
                SettingsToggle(
                    title: "Auto-Analyze Screenshots",
                    subtitle: "Process new screenshots automatically",
                    isOn: $autoAnalyze,
                    accentColor: .brandPrimary
                )
                
                Divider()
                    .background(Color.white.opacity(0.1))
                
                // Stealth Mode Toggle
                SettingsToggle(
                    title: "Stealth Mode",
                    subtitle: "Hide from Dock & App Switcher (⌘B)",
                    isOn: $stealthMode,
                    accentColor: .red
                )
                .onChange(of: stealthMode) { _, newValue in
                    applyStealthMode(newValue)
                    WindowManager.shared.updateSharingType(stealth: newValue)
                }
                
                Divider()
                    .background(Color.white.opacity(0.1))
                
                // Audio Language Picker
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Audio Language")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                        Text("Guided transcription for better accuracy")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    Picker("", selection: $audioLanguage) {
                        Text("Auto Detect").tag("auto")
                        Text("English").tag("en")
                        Text("Finnish").tag("fi")
                        Text("Turkish").tag("tr")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 100)
                    .tint(.brandPrimary)
                }
                
                Divider()
                    .background(Color.white.opacity(0.1))
                
                // No-Echo Audio Toggle
                SettingsToggle(
                    title: "No-Echo Mode",
                    subtitle: useExternalAudio ? "🎤 Microphone only" : "🔊 Mic + Digital Meeting Capture",
                    isOn: $useExternalAudio,
                    accentColor: .cyan
                )
                
                Divider()
                    .background(Color.white.opacity(0.1))
                
                // Open Captures Folder Button
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Screen Captures")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                        Text("Access locally saved screen analytics")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    Button(action: openCapturesFolder) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                            Text("Open Folder")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.interactive)
                    .pointerCursor()
                }
            }
        }
    }
    
    // MARK: - Appearance Section
    private var appearanceSection: some View {
        SettingsSection(title: "Appearance", icon: .sparkles) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Theme Color")
                    .foregroundColor(.white.opacity(0.8))
                    .font(.system(size: 13))
                
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40))], spacing: 10) {
                    ForEach(["Red", "Orange", "Blue", "Green", "Purple", "Graphite"], id: \.self) { theme in
                        ZStack {
                            Circle()
                                .fill(colorForTheme(theme))
                                .frame(width: 32, height: 32)
                                .onTapGesture {
                                    withAnimation {
                                        selectedTheme = theme
                                    }
                                }
                            
                            if selectedTheme == theme {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.white)
                                    .font(.system(size: 14, weight: .bold))
                            }
                        }
                        .pointerCursor()
                    }
                }
            }
        }
    }
    
    private func colorForTheme(_ name: String) -> Color {
        switch name {
        case "Red": return Color(red: 242/255, green: 78/255, blue: 78/255)
        case "Orange": return Color.orange
        case "Blue": return Color.blue
        case "Purple": return Color.purple
        case "Green": return Color.green
        case "Graphite": return Color(white: 0.3)
        default: return Color(red: 242/255, green: 78/255, blue: 78/255)
        }
    }

    // MARK: - API Keys Section
    private var apiKeysSection: some View {
        SettingsSection(title: "API Keys", icon: .gear) {
            VStack(alignment: .leading, spacing: 16) {
                // Show/Hide Toggle
                HStack {
                    Text(showKeys ? "Hide Keys" : "Show Keys")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Button(action: { showKeys.toggle() }) {
                        Image(systemName: showKeys ? "eye.slash" : "eye")
                            .foregroundColor(.brandPrimary)
                    }
                    .buttonStyle(.interactive)
                }
                
                Divider().background(Color.white.opacity(0.1))

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("OpenAI Key (Preferred)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                        if Secrets.isOpenAIKeyValid {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 12))
                        }
                    }
                    Text("Primary provider for live technical interview fallback and low-latency coding answers.")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))

                    if showKeys {
                        TextField("OpenAI API Key", text: $openAIKey)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: openAIKey) { Secrets.openAIApiKey = openAIKey }
                    } else {
                        SecureField("OpenAI API Key", text: $openAIKey)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: openAIKey) { Secrets.openAIApiKey = openAIKey }
                    }
                }
                
                // Ollama Key
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Ollama Cloud Key (Fallback)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                        if Secrets.isOllamaKeyValid {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 12))
                        }
                    }
                    Text("Optional fallback if OpenAI key is not available. Local embeddings continue to work without this key.")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                    if showKeys {
                        TextField("Ollama API Key", text: $ollamaKey)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: ollamaKey) { Secrets.ollamaApiKey = ollamaKey }
                    } else {
                        SecureField("Ollama API Key", text: $ollamaKey)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: ollamaKey) { Secrets.ollamaApiKey = ollamaKey }
                    }
                }
                
                // Groq Key
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Groq Key")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                        if Secrets.isGroqKeyValid {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 12))
                        }
                    }
                    if showKeys {
                        TextField("Groq API Key", text: $groqKey)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: groqKey) { Secrets.groqApiKey = groqKey }
                    } else {
                        SecureField("Groq API Key", text: $groqKey)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: groqKey) { Secrets.groqApiKey = groqKey }
                    }
                }
                
                // Tavily Key
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Tavily Key")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                        if Secrets.isTavilyKeyValid {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 12))
                        }
                    }
                    if showKeys {
                        TextField("Tavily API Key", text: $tavilyKey)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: tavilyKey) { Secrets.tavilyApiKey = tavilyKey }
                    } else {
                        SecureField("Tavily API Key", text: $tavilyKey)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: tavilyKey) { Secrets.tavilyApiKey = tavilyKey }
                    }
                }
                
                Divider().background(Color.white.opacity(0.1))
                
                // Clear Keys Button
                Button(action: {
                    Secrets.resetToDefaults()
                    loadAPIKeys()
                }) {
                    HStack {
                        Image(systemName: "trash")
                        Text("Clear Saved Keys")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(6)
                }
                .buttonStyle(.interactive)
                .pointerCursor()
            }
        }
        .onAppear { loadAPIKeys() }
    }
    
    private func loadAPIKeys() {
        openAIKey = Secrets.openAIApiKey
        ollamaKey = Secrets.ollamaApiKey
        groqKey = Secrets.groqApiKey
        tavilyKey = Secrets.tavilyApiKey
    }
    
    // MARK: - Hotkey Status Section
    @ViewBuilder
    private var hotkeyStatusSection: some View {
        if !hotkeyManager.isPermissionGranted {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Cmd+B Shortcut Inactive")
                        .font(.headline)
                        .foregroundColor(.white)
                }
                
                Text("Global hotkey could not be registered. This usually means Cmd+B is already captured by another app or shortcut tool.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                
                Button(action: {
                    hotkeyManager.start()
                }) {
                    Text("Retry Cmd+B Registration")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(6)
                }
                .buttonStyle(.interactive)
                .pointerCursor()
            }
            .padding(16)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.3), lineWidth: 1))
        }
    }
    
    private func applyStealthMode(_ enabled: Bool) {
        if enabled {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    private func refreshMemoryState() {
        Task {
            do {
                let count = try await DependencyContainer.shared.vectorStore.countEmbeddings()
                await MainActor.run {
                    memoryChunkCount = count
                    memoryStatus = count > 0 ? "Memory ready." : "No indexed memory yet."
                }
            } catch {
                await MainActor.run {
                    memoryChunkCount = 0
                    memoryStatus = "Memory status unavailable: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - File Import Logic
    private func importPersonaFile() {
        importTextFiles(
            message: "Select CVs or Documents to import context",
            prompt: "Import"
        ) { importedText, fileName in
            if !userPersonaContext.isEmpty {
                userPersonaContext += "\n\n"
            }
            userPersonaContext += "--- Imported Context (\(fileName)) ---\n"
            userPersonaContext += importedText
        }
    }

    private func importActiveRoleFile() {
        importTextFiles(
            message: "Select a job description PDF or text file",
            prompt: "Import Job Description"
        ) { importedText, fileName in
            logger.info("Imported active role file: \(fileName, privacy: .public)")
            activeJobDescription = importedText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func importTextFiles(
        message: String,
        prompt: String,
        append: (String, String) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .plainText, .text]
        panel.message = message
        panel.prompt = prompt
        
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let text = extractText(from: url) {
                    let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleanText.isEmpty {
                        append("[WARNING: No text extracted. This PDF might be a scanned image. Please convert to text/OCR first.]\n", url.lastPathComponent)
                    } else {
                        append(cleanText, url.lastPathComponent)
                    }
                }
            }
        }
    }
    
    private func extractText(from url: URL) -> String? {
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdfDocument = PDFDocument(url: url) else { return nil }
            var fullText = ""
            for i in 0..<pdfDocument.pageCount {
                if let page = pdfDocument.page(at: i), let pageText = page.string {
                    fullText += pageText + "\n"
                }
            }
            return fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // Text File
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }
    
    // MARK: - Handlers
    
    private func openCapturesFolder() {
        let fileManager = FileManager.default
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        
        let capturesURL = appSupportURL.appendingPathComponent("ZeroLose/Captures", isDirectory: true)
        
        // Ensure directory exists
        if !fileManager.fileExists(atPath: capturesURL.path) {
            try? fileManager.createDirectory(at: capturesURL, withIntermediateDirectories: true)
        }
        
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: capturesURL.path)
    }
}

// MARK: - Reusable Components

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: ZeroLoseIcon.IconType
    let content: Content
    
    init(title: String, icon: ZeroLoseIcon.IconType, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section Header
            HStack(spacing: 8) {
                ZeroLoseIcon(type: icon, color: .brandPrimary, size: 16)
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
            }
            
            // Section Content
            VStack(spacing: 12) {
                content
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
    }
}

struct SettingsRow<Content: View>: View {
    let label: String
    let value: String
    let content: Content
    
    init(label: String, value: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.value = value
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Text(value)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.brandPrimary)
            }
            content
        }
    }
}

struct SettingsToggle: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let accentColor: Color
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .tint(accentColor)
        }
    }
}

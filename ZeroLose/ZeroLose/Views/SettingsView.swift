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
    
    // API Keys
    @State private var openAIKey: String = ""
    @State private var ollamaKey: String = ""
    @State private var groqKey: String = ""
    @State private var tavilyKey: String = ""
    @State private var showKeys: Bool = false
    @State private var memoryChunkCount: Int = 0
    @State private var isClearingMemory: Bool = false
    @State private var memoryStatus: String = ""
    @State private var selectedTab: SettingsTab = .general
    @State private var isDraggingOverCV = false
    @State private var isDraggingOverJD = false
    @State private var openaiModels: [String] = []
    @State private var ollamaModels: [String] = []
    
    @ObservedObject private var hotkeyManager = HotkeyManager.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.zerolose", category: "SettingsView")
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            settingsHeader
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 14)
            
            // Tab Selector
            tabSelectorBar
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            
            Divider()
                .overlay(Color.glassStroke)
            
            // Scrollable Content
            ScrollView {
                VStack(spacing: 24) {
                    switch selectedTab {
                    case .general:
                        generalTabView
                    case .api:
                        apiTabView
                    case .context:
                        contextTabView
                    case .system:
                        systemTabView
                    case .memory:
                        memoryTabView
                    }
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Semi-translucent overlay to combine with window-level blur
            Color.black.opacity(0.15)
                .ignoresSafeArea()
        }
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
    
    // MARK: - Tab Bar Components
    
    private var tabSelectorBar: some View {
        HStack(spacing: 8) {
            ForEach(SettingsTab.allCases) { tab in
                Button(action: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                        selectedTab = tab
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .bold))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 12)
                    .background(selectedTab == tab ? Color.brandPrimary.opacity(0.18) : Color.glassFill)
                    .foregroundColor(selectedTab == tab ? .white : Color.textSecondary)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(selectedTab == tab ? Color.brandPrimary.opacity(0.4) : Color.glassStroke, lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }
    
    @ViewBuilder
    private var generalTabView: some View {
        HStack(alignment: .top, spacing: 20) {
            appearanceSection
                .frame(maxWidth: .infinity)
            typographySection
                .frame(maxWidth: .infinity)
        }
        windowSection
    }
    
    @ViewBuilder
    private var apiTabView: some View {
        apiKeysSection
    }
    
    @ViewBuilder
    private var contextTabView: some View {
        activeRoleSection
        personaSection
        storedContextSection
    }
    
    @ViewBuilder
    private var systemTabView: some View {
        hotkeyStatusSection
        featuresSection
    }
    
    @ViewBuilder
    private var memoryTabView: some View {
        memorySection
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
                    .foregroundColor(Color.textSecondary)
            }
            .buttonStyle(.interactive)
            .pointerCursor()
        }
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
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color.textPrimary)
                    Spacer()
                    Picker("", selection: $fontDesignObj) {
                        Text("Mono").tag("monospaced")
                        Text("System").tag("default")
                        Text("Serif").tag("serif")
                        Text("Rounded").tag("rounded")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 110)
                    .tint(.brandPrimary)
                }
            }
        }
    }
    
    // MARK: - Persona Section
    private var personaSection: some View {
        SettingsSection(title: "Persona & Context (CV)", icon: .brain) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Paste or drop your CV / Experience Summary here (PDF/TXT supported). AI personalizes answers based on this.")
                        .font(.system(size: 11))
                        .foregroundColor(Color.textSecondary)
                        .lineLimit(2)
                    
                    Spacer()
                    
                    // Import PDF/Text Button
                    Button(action: importPersonaFile) {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.down")
                            Text("Import PDF/TXT")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .background(Color.glassFill)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.glassStroke, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.interactive)
                    .pointerCursor()
                }
                
                TextEditor(text: $userPersonaContext)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.black.opacity(0.18))
                    .cornerRadius(8)
                    .frame(height: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isDraggingOverCV ? Color.brandPrimary : Color.glassStroke, lineWidth: isDraggingOverCV ? 1.5 : 0.8)
                    )
            }
            .background {
                if isDraggingOverCV {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.brandPrimary.opacity(0.08))
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDraggingOverCV) { providers in
                handleCVDrop(providers)
            }
        }
    }

    private var activeRoleSection: some View {
        let preview = ActiveRoleProfileService.previewSummary(for: activeJobDescription)

        return SettingsSection(title: "Active Interview Role", icon: .book) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Paste or drop the job description PDF/TXT file here. AI uses it to ground answers.")
                        .font(.system(size: 11))
                        .foregroundColor(Color.textSecondary)
                        .lineLimit(2)

                    Spacer()

                    Button(action: importActiveRoleFile) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text.fill")
                            Text("Import JD")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .background(Color.glassFill)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.glassStroke, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.interactive)
                    .pointerCursor()
                }

                TextEditor(text: $activeJobDescription)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.black.opacity(0.18))
                    .cornerRadius(8)
                    .frame(height: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isDraggingOverJD ? Color.brandPrimary : Color.glassStroke, lineWidth: isDraggingOverJD ? 1.5 : 0.8)
                    )

                VStack(alignment: .leading, spacing: 6) {
                    Text("Parsed Role Pack")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.orange.opacity(0.9))

                    Text(preview)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.glassFill)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.orange.opacity(0.16), lineWidth: 0.8)
                        )
                }
            }
            .background {
                if isDraggingOverJD {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.brandPrimary.opacity(0.08))
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDraggingOverJD) { providers in
                handleJDDrop(providers)
            }
        }
    }
    
    // MARK: - Memory Section
    private var memorySection: some View {
        SettingsSection(title: "Memory (RAG)", icon: .brain) {
            VStack(alignment: .leading, spacing: 12) {
                Text("AI remembers PDFs and conversations stored in the local vector database.")
                    .font(.system(size: 11))
                    .foregroundColor(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Indexed Documents")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                        Text("PDFs, chat history chunks")
                            .font(.system(size: 11))
                            .foregroundColor(Color.textSecondary)
                    }
                    
                    Spacer()
                    
                    // Document count badge
                    Text("\(memoryChunkCount) chunks")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(memoryChunkCount > 0 ? .green : .orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background((memoryChunkCount > 0 ? Color.green : Color.orange).opacity(0.12))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder((memoryChunkCount > 0 ? Color.green : Color.orange).opacity(0.3), lineWidth: 0.5)
                        )
                }
                
                if !memoryStatus.isEmpty {
                    Text(memoryStatus)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                }
                
                Divider()
                    .overlay(Color.glassStroke)
                
                // Clear Memory Button
                Button(action: clearMemory) {
                    HStack {
                        Image(systemName: "trash")
                        Text(isClearingMemory ? "Clearing..." : "Clear All Memory")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.red.opacity(0.9))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.red.opacity(0.3), lineWidth: 0.8)
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
                    .foregroundColor(Color.textSecondary)
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
                .foregroundColor(isEnabled ? .orange.opacity(0.9) : .white.opacity(0.3))
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(isEnabled ? Color.orange.opacity(0.08) : Color.white.opacity(0.03))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isEnabled ? Color.orange.opacity(0.28) : Color.white.opacity(0.08), lineWidth: 0.8)
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
        SettingsSection(title: "Window Settings", icon: .gear) {
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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 14)
                    .background(Color.glassFill)
                    .cornerRadius(14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.glassStroke, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.interactive)
                .pointerCursor()
            }
        }
    }
    
    // MARK: - Features Section
    private var featuresSection: some View {
        SettingsSection(title: "Features & Integrations", icon: .eye) {
            VStack(spacing: 16) {
                // Auto-Analyze Toggle
                SettingsToggle(
                    title: "Auto-Analyze Screenshots",
                    subtitle: "Process new screenshots automatically",
                    isOn: $autoAnalyze,
                    accentColor: .brandPrimary
                )
                
                Divider()
                    .overlay(Color.glassStroke)
                
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
                    .overlay(Color.glassStroke)
                
                // Audio Language Picker
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Audio Language")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                        Text("Guided transcription for better accuracy")
                            .font(.system(size: 12))
                            .foregroundColor(Color.textSecondary)
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
                    .frame(width: 110)
                    .tint(.brandPrimary)
                }
                
                Divider()
                    .overlay(Color.glassStroke)
                
                // No-Echo Audio Toggle
                SettingsToggle(
                    title: "No-Echo Mode",
                    subtitle: useExternalAudio ? "🎤 Microphone only" : "🔊 Mic + Digital Meeting Capture",
                    isOn: $useExternalAudio,
                    accentColor: .cyan
                )
                
                Divider()
                    .overlay(Color.glassStroke)
                
                // Open Captures Folder Button
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Screen Captures")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                        Text("Access locally saved screen analytics")
                            .font(.system(size: 12))
                            .foregroundColor(Color.textSecondary)
                    }
                    Spacer()
                    Button(action: openCapturesFolder) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                            Text("Open Folder")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.glassFill)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.glassStroke, lineWidth: 0.5)
                        )
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
                    .foregroundColor(Color.textPrimary)
                    .font(.system(size: 13, weight: .medium))
                
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40))], spacing: 10) {
                    ForEach(["Red", "Orange", "Blue", "Green", "Purple", "Graphite"], id: \.self) { theme in
                        ZStack {
                            Circle()
                                .fill(colorForTheme(theme))
                                .frame(width: 30, height: 30)
                                .onTapGesture {
                                    withAnimation {
                                        selectedTheme = theme
                                    }
                                }
                            
                            if selectedTheme == theme {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.white)
                                    .font(.system(size: 13, weight: .bold))
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
        case "Red":      return Color(red: 242/255, green: 78/255, blue: 78/255)
        case "Orange":   return Color.orange
        case "Blue":     return Color(red: 0.2, green: 0.6, blue: 1.0)
        case "Purple":   return Color(red: 0.7, green: 0.3, blue: 1.0)
        case "Green":    return Color(red: 0.2, green: 0.85, blue: 0.5)
        case "Graphite": return Color(white: 0.5)
        default:         return Color(red: 242/255, green: 78/255, blue: 78/255)
        }
    }

    // MARK: - API Keys Section
    private var apiKeysSection: some View {
        SettingsSection(title: "API Keys", icon: .gear) {
            VStack(alignment: .leading, spacing: 16) {
                // Show/Hide Toggle
                HStack {
                    Text(showKeys ? "Hide Keys" : "Show Keys")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.textSecondary)
                    Spacer()
                    Button(action: { showKeys.toggle() }) {
                        Image(systemName: showKeys ? "eye.slash" : "eye")
                            .foregroundColor(.brandPrimary)
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.interactive)
                }
                
                Divider()
                    .overlay(Color.glassStroke)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("OpenAI Key (Preferred)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                        Spacer()
                        if Secrets.isOpenAIKeyValid {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 12))
                        }
                    }
                    Text("Primary provider for live technical interview fallback and low-latency coding answers.")
                        .font(.system(size: 10))
                        .foregroundColor(Color.textSecondary)

                    if showKeys {
                        TextField("OpenAI API Key", text: $openAIKey)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(Color.black.opacity(0.18))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.glassStroke, lineWidth: 0.8))
                            .onChange(of: openAIKey) { Secrets.openAIApiKey = openAIKey; fetchModels() }
                    } else {
                        SecureField("OpenAI API Key", text: $openAIKey)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(Color.black.opacity(0.18))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.glassStroke, lineWidth: 0.8))
                            .onChange(of: openAIKey) { Secrets.openAIApiKey = openAIKey; fetchModels() }
                    }
                }
                
                // Ollama Key
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Ollama Cloud Key (Fallback)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                        Spacer()
                        if Secrets.isOllamaKeyValid {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 12))
                        }
                    }
                    Text("Optional fallback if OpenAI key is not available. Local embeddings continue to work without this key.")
                        .font(.system(size: 10))
                        .foregroundColor(Color.textSecondary)
                    if showKeys {
                        TextField("Ollama API Key", text: $ollamaKey)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(Color.black.opacity(0.18))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.glassStroke, lineWidth: 0.8))
                            .onChange(of: ollamaKey) { Secrets.ollamaApiKey = ollamaKey; fetchModels() }
                    } else {
                        SecureField("Ollama API Key", text: $ollamaKey)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(Color.black.opacity(0.18))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.glassStroke, lineWidth: 0.8))
                            .onChange(of: ollamaKey) { Secrets.ollamaApiKey = ollamaKey; fetchModels() }
                    }
                }
                
                // Groq Key
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Groq Key")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                        Spacer()
                        if Secrets.isGroqKeyValid {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 12))
                        }
                    }
                    if showKeys {
                        TextField("Groq API Key", text: $groqKey)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(Color.black.opacity(0.18))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.glassStroke, lineWidth: 0.8))
                            .onChange(of: groqKey) { Secrets.groqApiKey = groqKey }
                    } else {
                        SecureField("Groq API Key", text: $groqKey)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(Color.black.opacity(0.18))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.glassStroke, lineWidth: 0.8))
                            .onChange(of: groqKey) { Secrets.groqApiKey = groqKey }
                    }
                }
                
                // Tavily Key
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Tavily Key")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                        Spacer()
                        if Secrets.isTavilyKeyValid {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 12))
                        }
                    }
                    if showKeys {
                        TextField("Tavily API Key", text: $tavilyKey)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(Color.black.opacity(0.18))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.glassStroke, lineWidth: 0.8))
                            .onChange(of: tavilyKey) { Secrets.tavilyApiKey = tavilyKey }
                    } else {
                        SecureField("Tavily API Key", text: $tavilyKey)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(Color.black.opacity(0.18))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.glassStroke, lineWidth: 0.8))
                            .onChange(of: tavilyKey) { Secrets.tavilyApiKey = tavilyKey }
                    }
                }
                
                Divider()
                    .overlay(Color.glassStroke)
                
                // Model Configuration Override
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        ZeroLoseIcon(type: .sparkles, color: .brandPrimary, size: 14)
                        Text("Model Selection & Customization")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    
                    Text("Select which models to target for each LLM query type. ZeroLose will use these when the corresponding provider keys are valid.")
                        .font(.system(size: 10))
                        .foregroundColor(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    VStack(spacing: 8) {
                        if Secrets.isOpenAIKeyValid {
                            let openAIOpts = openaiModels.isEmpty ? ["gpt-5-mini", "gpt-4o", "gpt-4o-mini"] : openaiModels
                            modelSelectorRow(label: "OpenAI Fast Model", key: "customOpenAIFastModel", options: openAIOpts)
                            modelSelectorRow(label: "OpenAI Vision Model", key: "customOpenAIVisionModel", options: openAIOpts)
                            modelSelectorRow(label: "OpenAI Reasoning Model", key: "customOpenAIReasoningModel", options: openAIOpts)
                            modelSelectorRow(label: "OpenAI Coding Model", key: "customOpenAICodingModel", options: openAIOpts)
                        } else {
                            let ollamaOpts = ollamaModels.isEmpty ? ["qwen2.5:7b-cloud", "gemma2:9b-cloud", "llama3.1:8b-cloud", "qwen2.5-coder:7b-cloud", "gpt-oss:120b", "nemotron-3-ultra"] : ollamaModels
                            modelSelectorRow(label: "Ollama Fast Model", key: "customOllamaFastModel", options: ollamaOpts)
                            modelSelectorRow(label: "Ollama Vision Model", key: "customOllamaVisionModel", options: ollamaOpts)
                            modelSelectorRow(label: "Ollama Reasoning Model", key: "customOllamaReasoningModel", options: ollamaOpts)
                            modelSelectorRow(label: "Ollama Coding Model", key: "customOllamaCodingModel", options: ollamaOpts)
                        }
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.18))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.glassStroke, lineWidth: 0.8))
                }
                
                Divider()
                    .overlay(Color.glassStroke)
                
                // Clear Keys Button
                Button(action: {
                    Secrets.resetToDefaults()
                    loadAPIKeys()
                }) {
                    HStack {
                        Image(systemName: "trash")
                        Text("Clear Saved Keys")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(Color.glassFill)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.glassStroke, lineWidth: 0.5))
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
        fetchModels()
    }
    
    private func fetchModels() {
        let openAIKeyVal = Secrets.openAIApiKey
        let ollamaKeyVal = Secrets.ollamaApiKey
        
        if !openAIKeyVal.isEmpty {
            Task {
                let models = await DependencyContainer.shared.ollamaService.fetchAvailableModels(provider: "openai", apiKey: openAIKeyVal)
                await MainActor.run {
                    self.openaiModels = models
                }
            }
        } else {
            self.openaiModels = []
        }
        
        if !ollamaKeyVal.isEmpty {
            Task {
                let models = await DependencyContainer.shared.ollamaService.fetchAvailableModels(provider: "ollama", apiKey: ollamaKeyVal)
                await MainActor.run {
                    self.ollamaModels = models
                }
            }
        } else {
            self.ollamaModels = []
        }
    }
    
    // MARK: - Hotkey Status Section
    @ViewBuilder
    private var hotkeyStatusSection: some View {
        if !hotkeyManager.isPermissionGranted {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Cmd+B Shortcut Inactive")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                
                Text("Global hotkey could not be registered. This usually means Cmd+B is already captured by another app or shortcut tool.")
                    .font(.system(size: 11))
                    .foregroundColor(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                Button(action: {
                    hotkeyManager.start()
                }) {
                    Text("Retry Cmd+B Registration")
                        .font(.system(size: 11, weight: .semibold))
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
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.3), lineWidth: 0.8))
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
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }
    
    private func openCapturesFolder() {
        let fileManager = FileManager.default
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        
        let capturesURL = appSupportURL.appendingPathComponent("ZeroLose/Captures", isDirectory: true)
        if !fileManager.fileExists(atPath: capturesURL.path) {
            try? fileManager.createDirectory(at: capturesURL, withIntermediateDirectories: true)
        }
        
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: capturesURL.path)
    }
    
    private func handleCVDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
            guard let data = data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            
            Task { @MainActor in
                if let text = DocumentParserService.shared.extractText(from: url) {
                    if !userPersonaContext.isEmpty {
                        userPersonaContext += "\n\n"
                    }
                    userPersonaContext += "--- Imported Context (\(url.lastPathComponent)) ---\n"
                    userPersonaContext += text
                    self.logger.info("CV document drag-dropped and parsed: \(url.lastPathComponent)")
                }
            }
        }
        return true
    }
    
    private func handleJDDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
            guard let data = data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            
            Task { @MainActor in
                if let text = DocumentParserService.shared.extractText(from: url) {
                    activeJobDescription = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.logger.info("JD document drag-dropped and parsed: \(url.lastPathComponent)")
                }
            }
        }
        return true
    }
    
    private func modelSelectorRow(label: String, key: String, options: [String]) -> some View {
        let binding = Binding<String>(
            get: { UserDefaults.standard.string(forKey: key) ?? options.first ?? "" },
            set: { UserDefaults.standard.set($0, forKey: key) }
        )
        
        return HStack {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
            Spacer()
            Picker("", selection: binding) {
                ForEach(options, id: \.self) { opt in
                    Text(opt).tag(opt)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 200)
            .tint(.brandPrimary)
        }
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
        VStack(alignment: .leading, spacing: 14) {
            // Section Header
            HStack(spacing: 8) {
                ZeroLoseIcon(type: icon, color: .brandPrimary, size: 15)
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(Color.textSecondary)
            }
            
            // Section Content
            VStack(spacing: 12) {
                content
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.glassFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.glassStroke, lineWidth: 0.8)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color.textPrimary)
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Color.textSecondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .tint(accentColor)
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case api = "API Keys"
    case context = "Context & JD"
    case system = "Voice & System"
    case memory = "Memory"
    
    var id: String { self.rawValue }
    
    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .api: return "key.fill"
        case .context: return "doc.text.fill"
        case .system: return "cpu.fill"
        case .memory: return "brain.fill"
        }
    }
}

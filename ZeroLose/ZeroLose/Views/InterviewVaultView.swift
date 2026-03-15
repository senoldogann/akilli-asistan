import AppKit
import SwiftUI
import UniformTypeIdentifiers
// InterviewVaultView.swift - Updated to use VaultService

struct InterviewVaultView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var vaultService = VaultService.shared
    @AppStorage("activeJobDescription") private var activeJobDescription: String = ""
    @State private var expandedCategory: UUID? = nil
    @State private var isClosing = false
    @State private var searchQuery: String = ""
    @State private var searchResults: [VaultSearchEngine.Result] = []
    @State private var searchIndex: VaultSearchEngine.Index = .empty
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var highlightedCategoryID: UUID? = nil
    @State private var highlightedItemID: UUID? = nil
    @State private var lastAutoFocusedResultID: String? = nil
    @State private var warmUpFeedback: String? = nil
    @State private var warmUpFeedbackIsWarning = false
    @State private var warmUpFeedbackTask: Task<Void, Never>? = nil
    
    // Management State
    @State private var editingItem: (categoryID: UUID, item: VaultInterviewItem)? = nil
    @State private var isAddingItem: UUID? = nil // categoryID
    @State private var isAddingCategory: Bool = false
    
    // Action handler for Warm-up
    var onWarmUp: (() -> String)?
    
    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // Header
                HStack {
                    ZeroLoseIcon(type: .book, color: .orange, size: 22)
                    Text(vaultTitle)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Button(action: {
                        triggerWarmUp()
                    }) {
                        HStack(spacing: 6) {
                            ZeroLoseIcon(type: .sparkles, color: .white, size: 12)
                            Text("WARM UP AI")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .cornerRadius(20)
                        .shadow(color: .orange.opacity(0.3), radius: 5, x: 0, y: 2)
                    }
                    .buttonStyle(.interactive)
                    .pointerCursor()

                    Button(action: importVault) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down.on.square")
                                .font(.system(size: 11, weight: .bold))
                            Text("IMPORT JSON")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(Color.white.opacity(0.08))
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .cornerRadius(20)
                    }
                    .buttonStyle(.interactive)
                    .pointerCursor()

                    Button(action: exportVault) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 11, weight: .bold))
                            Text("EXPORT JSON")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(Color.white.opacity(0.08))
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .cornerRadius(20)
                    }
                    .buttonStyle(.interactive)
                    .pointerCursor()
                    
                    Button(action: dismissSafely) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.interactive)
                    .pointerCursor()
                    .padding(.leading, 8)
                }
                .padding(20)
                .background(Color.white.opacity(0.05))
                
                if let warmUpFeedback {
                    Text(warmUpFeedback)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(warmUpFeedbackIsWarning ? .orange : .green)
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                        .padding(.bottom, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                searchBar(proxy: proxy)
                    .padding(.horizontal, 20)
                    .padding(.top, warmUpFeedback == nil ? 14 : 0)
                    .padding(.bottom, 6)
                
                // List
                ScrollView {
                    VStack(spacing: 16) {
                        // Add Category Button
                        Button(action: { isAddingCategory = true }) {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("Add New Category")
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.orange)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.interactive)
                        .pointerCursor()
                        
                        ForEach(vaultService.categories) { category in
                            CategoryView(
                                category: category,
                                isExpanded: expandedCategory == category.id,
                                isSearchMatch: highlightedCategoryID == category.id,
                                highlightedItemID: highlightedItemID,
                                onTap: {
                                    withAnimation(.spring(response: 0.3)) {
                                        if expandedCategory == category.id {
                                            expandedCategory = nil
                                        } else {
                                            expandedCategory = category.id
                                        }
                                    }
                                },
                                onAddItem: {
                                    isAddingItem = category.id
                                },
                                onDelete: {
                                    vaultService.deleteCategory(id: category.id)
                                }
                            )
                            .id(category.id)
                        }
                    }
                    .padding(20)
                }
            }
            .onChange(of: searchQuery) { _, newValue in
                handleSearchChange(newValue, proxy: proxy)
            }
            .onAppear {
                refreshSearchIndex()
            }
            .onReceive(vaultService.$categories) { _ in
                refreshSearchIndex()
                handleSearchChange(searchQuery, proxy: proxy)
            }
        }
        .frame(minWidth: 350, idealWidth: 500, maxWidth: 900, minHeight: 400, idealHeight: 650, maxHeight: 1000)
        .background(Color(red: 0.1, green: 0.1, blue: 0.12))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(radius: 30)
        .sheet(isPresented: $isAddingCategory) {
            AddCategoryView(isPresented: $isAddingCategory)
        }
        .sheet(item: Binding(
            get: { isAddingItem.map { IDWrapper(id: $0) } },
            set: { isAddingItem = $0?.id }
        )) { wrapper in
            EditItemView(categoryID: wrapper.id, item: nil)
        }
        .sheet(item: Binding(
            get: { editingItem.map { ItemWrapper(categoryID: $0.categoryID, item: $0.item) } },
            set: { editingItem = $0.map { ($0.categoryID, $0.item) } }
        )) { wrapper in
            EditItemView(categoryID: wrapper.categoryID, item: wrapper.item)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("EditVaultItem"))) { notification in
            if let userInfo = notification.userInfo,
               let categoryID = userInfo["categoryID"] as? UUID,
               let item = userInfo["item"] as? VaultInterviewItem {
                editingItem = (categoryID, item)
            }
        }
    }
}

// Helpers for Sheet Identifiable items
struct IDWrapper: Identifiable {
    let id: UUID
}

struct ItemWrapper: Identifiable {
    let categoryID: UUID
    let item: VaultInterviewItem
    
    var id: UUID { item.id }
}

private extension InterviewVaultView {
    var vaultTitle: String {
        guard let profile = ActiveRoleProfileService.profile(from: activeJobDescription),
              !profile.company.isEmpty else {
            return "Interview Vault"
        }
        return "\(profile.company) Interview Vault"
    }

    func searchBar(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.orange.opacity(0.8))

                TextField("Search question or answer...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.white)

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        searchResults = []
                        highlightedCategoryID = nil
                        highlightedItemID = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .buttonStyle(.interactive)
                    .pointerCursor()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.orange.opacity(searchQuery.isEmpty ? 0.14 : 0.32), lineWidth: 1)
            )
            .cornerRadius(12)

            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResultsPanel(proxy: proxy)
            }
        }
    }

    @ViewBuilder
    func searchResultsPanel(proxy: ScrollViewProxy) -> some View {
        if searchResults.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.magnifyingglass")
                    .foregroundColor(.orange.opacity(0.85))
                Text("No close match yet")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.62))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.035))
            .cornerRadius(10)
        } else {
            VStack(spacing: 6) {
                ForEach(searchResults) { result in
                    Button {
                        focusSearchResult(result, proxy: proxy, forceScroll: true)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: result.kind == .item ? "quote.bubble.fill" : "folder.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(result.kind == .item ? .orange : .blue.opacity(0.85))
                                .frame(width: 14, height: 14)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.title)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white.opacity(0.92))
                                    .lineLimit(1)
                                Text(result.categoryTitle)
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundColor(.orange.opacity(0.82))
                                    .lineLimit(1)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle)
                                        .font(.system(size: 10, weight: .regular, design: .rounded))
                                        .foregroundColor(.white.opacity(0.56))
                                        .lineLimit(2)
                                }
                            }

                            Spacer(minLength: 0)

                            if searchResults.first?.id == result.id {
                                Text("BEST")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(Color.orange.opacity(0.12))
                                    .cornerRadius(999)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(searchResults.first?.id == result.id ? Color.orange.opacity(0.09) : Color.white.opacity(0.035))
                    .cornerRadius(10)
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
    }

    func triggerWarmUp() {
        let totalItems = vaultService.categories.reduce(0) { $0 + $1.items.count }
        let fallbackMessage = totalItems > 0
            ? "🔥 Interview context yüklendi (\(totalItems) soru)."
            : "⚠️ Vault boş. Sadece temel interview context yüklendi."
        
        let message = onWarmUp?() ?? fallbackMessage
        showFeedback(message, isWarning: message.hasPrefix("⚠️"))
    }

    func exportVault() {
        let panel = NSSavePanel()
        panel.title = "Export Interview Vault"
        panel.message = "Save all categories, questions, and answers as JSON."
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = defaultExportFilename()

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try vaultService.exportCurrentVault(to: url)
            let totalItems = vaultService.categories.reduce(0) { $0 + $1.items.count }
            showFeedback(
                "✅ Vault exported (\(vaultService.categories.count) kategori, \(totalItems) soru).",
                isWarning: false
            )
        } catch {
            showFeedback("⚠️ Vault export failed: \(error.localizedDescription)", isWarning: true)
        }
    }

    func importVault() {
        let panel = NSOpenPanel()
        panel.title = "Import Interview Vault"
        panel.message = "Choose a JSON file exported from Interview Vault."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        guard let strategy = importStrategyPrompt() else {
            return
        }

        do {
            let summary = try vaultService.importVault(from: url, strategy: strategy)
            let modeLabel = strategy == .mergeExisting ? "merged" : "replaced"
            showFeedback(
                "✅ Vault \(modeLabel) (\(summary.totalCategories) kategori, \(summary.totalQuestions) soru).",
                isWarning: false
            )
        } catch {
            showFeedback("⚠️ Vault import failed: \(error.localizedDescription)", isWarning: true)
        }
    }

    func importStrategyPrompt() -> VaultImportStrategy? {
        let alert = NSAlert()
        alert.messageText = "How should the imported vault be applied?"
        alert.informativeText = "Replace will overwrite the current Interview Vault. Merge will combine categories and questions by title/question."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Replace Current")
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .replaceExisting
        case .alertSecondButtonReturn:
            return .mergeExisting
        default:
            return nil
        }
    }

    func defaultExportFilename() -> String {
        let base = vaultTitle
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: " interview vault", with: "")
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let safeBase = base.isEmpty ? "interview-vault" : base
        return "\(safeBase)-interview-vault.json"
    }

    func showFeedback(_ message: String, isWarning: Bool) {
        warmUpFeedbackTask?.cancel()
        warmUpFeedback = message
        warmUpFeedbackIsWarning = isWarning

        warmUpFeedbackTask = Task {
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
            await MainActor.run {
                self.warmUpFeedback = nil
                self.warmUpFeedbackIsWarning = false
            }
        }
    }

    func handleSearchChange(_ rawQuery: String, proxy: ScrollViewProxy) {
        searchTask?.cancel()
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            highlightedCategoryID = nil
            highlightedItemID = nil
            lastAutoFocusedResultID = nil
            return
        }

        let index = searchIndex.isEmpty ? VaultSearchEngine.makeIndex(categories: vaultService.categories) : searchIndex

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }

            let rankedResults = await Task.detached(priority: .userInitiated) {
                VaultSearchEngine.rankedResults(
                    query: query,
                    index: index
                )
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                applySearchResults(rankedResults, proxy: proxy)
            }
        }
    }

    func refreshSearchIndex() {
        searchIndex = VaultSearchEngine.makeIndex(categories: vaultService.categories)
    }

    func applySearchResults(_ rankedResults: [VaultSearchEngine.Result], proxy: ScrollViewProxy) {
        searchResults = rankedResults

        guard let target = rankedResults.first else {
            highlightedCategoryID = nil
            highlightedItemID = nil
            lastAutoFocusedResultID = nil
            return
        }

        focusSearchResult(target, proxy: proxy)
    }

    func focusSearchResult(
        _ target: VaultSearchEngine.Result,
        proxy: ScrollViewProxy,
        forceScroll: Bool = false
    ) {
        highlightedCategoryID = target.categoryID
        highlightedItemID = target.itemID

        let shouldAutoFocus = forceScroll || lastAutoFocusedResultID != target.id
        lastAutoFocusedResultID = target.id

        if expandedCategory != target.categoryID {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                expandedCategory = target.categoryID
            }
        }

        guard shouldAutoFocus else { return }

        let scrollID: AnyHashable = target.itemID ?? target.categoryID
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(scrollID, anchor: .center)
            }
        }
    }
    
    func dismissSafely() {
        guard !isClosing else { return }
        isClosing = true
        
        // Tear down child modal states first to avoid ViewBridge teardown races.
        isAddingCategory = false
        isAddingItem = nil
        editingItem = nil
        expandedCategory = nil
        
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isPresented = false
        }
    }
}
    

struct CategoryView: View {
    let category: VaultInterviewCategory
    let isExpanded: Bool
    let isSearchMatch: Bool
    let highlightedItemID: UUID?
    let onTap: () -> Void
    var onAddItem: () -> Void
    var onDelete: () -> Void
    
    @AppStorage("fontSize") private var fontSize: Double = 14.0
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack {
                    Image(systemName: category.icon)
                        .foregroundColor(.orange)
                        .font(.system(size: CGFloat(fontSize) + 2))
                        .frame(width: 24)
                    
                    Text(category.title)
                        .font(.system(size: CGFloat(fontSize) + 1, weight: .semibold))
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                HStack(spacing: 12) {
                    Button(action: onAddItem) {
                        Image(systemName: "plus.circle")
                            .foregroundColor(.green.opacity(0.8))
                    }
                    .buttonStyle(.interactive)
                    
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundColor(.red.opacity(0.6))
                    }
                    .buttonStyle(.interactive)
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.3))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .padding(16)
            .background(Color.white.opacity(0.03))
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(category.items) { item in
                        ItemView(
                            item: item,
                            categoryID: category.id,
                            isSearchMatch: highlightedItemID == item.id
                        )
                        .id(item.id)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(isSearchMatch ? Color.orange.opacity(0.12) : Color.black.opacity(0.2))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isSearchMatch
                    ? Color.orange.opacity(0.45)
                    : Color.white.opacity(isExpanded ? 0.1 : 0.05),
                    lineWidth: 1
                )
        )
    }
}

struct ItemView: View {
    let item: VaultInterviewItem
    let categoryID: UUID
    let isSearchMatch: Bool
    @ObservedObject private var vaultService = VaultService.shared
    
    // Dynamic Font Settings
    @AppStorage("fontSize") private var fontSize: Double = 14.0
    @AppStorage("fontDesign") private var fontDesignStr: String = "monospaced"
    
    var fontDesign: Font.Design {
        switch fontDesignStr {
        case "serif": return .serif
        case "rounded": return .rounded
        case "default": return .default
        default: return .monospaced
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Question Header
            HStack {
                Text(item.question)
                    .font(.system(size: CGFloat(fontSize), weight: .medium, design: fontDesign))
                    .foregroundColor(.white.opacity(0.95))
                    .multilineTextAlignment(.leading)
                
                Spacer()
                
                HStack(spacing: 12) {
                    Button(action: {
                        // This should trigger the editing sheet in the parent
                        // We'll use a hack or a better state management. 
                        // For now let's assume we can trigger it.
                        NotificationCenter.default.post(name: NSNotification.Name("EditVaultItem"), object: nil, userInfo: ["categoryID": categoryID, "item": item])
                    }) {
                        Image(systemName: "pencil")
                            .foregroundColor(.blue.opacity(0.7))
                    }
                    .buttonStyle(.interactive)
                    
                    Button(action: {
                        vaultService.deleteItem(from: categoryID, itemID: item.id)
                    }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red.opacity(0.5))
                    }
                    .buttonStyle(.interactive)
                }
            }
            
            // Answer Content (Always Visible)
            VStack(alignment: .leading, spacing: 8) {
                Text(item.answerFinnish)
                    .font(.system(size: CGFloat(fontSize), design: fontDesign)) // Use user selected font
                    // Tooltip for translation / search alias
                    .help(item.translationTr)
                    .foregroundColor(.white.opacity(0.85))
                    .lineSpacing(4)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.05))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.orange.opacity(0.1), lineWidth: 1)
                    )
                
                HStack {
                    ForEach(item.keyPoints, id: \.self) { point in
                        Text(point)
                            .font(.system(size: CGFloat(fontSize) - 4)) // Slightly smaller than body
                            .foregroundColor(.gray)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(4)
                    }
                }
            }
            .padding(12)
            .background(isSearchMatch ? Color.orange.opacity(0.08) : Color.clear)
            .cornerRadius(10)
        }
        .padding(16)
        .background(Color.white.opacity(0.02))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.white.opacity(0.03)),
            alignment: .top
        )
    }
}

// MARK: - Management Views

struct AddCategoryView: View {
    @Binding var isPresented: Bool
    @State private var title: String = ""
    @State private var icon: String = "folder.fill"
    
    var body: some View {
        VStack(spacing: 20) {
            Text("New Category")
                .font(.headline)
            
            TextField("Category Title", text: $title)
                .textFieldStyle(.roundedBorder)
            
            TextField("SF Symbol Icon Name", text: $icon)
                .textFieldStyle(.roundedBorder)
            
            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button("Add") {
                    VaultService.shared.addCategory(VaultInterviewCategory(title: title, icon: icon, items: []))
                    isPresented = false
                }
                .buttonStyle(.interactive)
            }
            .buttonStyle(.interactive)
        }
        .padding()
        .frame(width: 300)
    }
}

struct EditItemView: View {
    let categoryID: UUID
    let item: VaultInterviewItem? // nil if adding
    
    @Environment(\.dismiss) var dismiss
    @State private var question: String = ""
    @State private var answerFinnish: String = ""
    @State private var translationTr: String = ""
    @State private var keyPointsStr: String = ""
    
    var body: some View {
        VStack(spacing: 16) {
            Text(item == nil ? "Add Question" : "Edit Question")
                .font(.headline)
                .foregroundColor(.white)
            
            ScrollView {
                VStack(spacing: 12) {
                    VStack(alignment: .leading) {
                        Text("Question").font(.caption).foregroundColor(.gray)
                        TextEditor(text: $question)
                            .frame(height: 60)
                            .cornerRadius(4)
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Answer (Finnish)").font(.caption).foregroundColor(.gray)
                        TextEditor(text: $answerFinnish)
                            .frame(height: 100)
                            .cornerRadius(4)
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Translation / Search Alias").font(.caption).foregroundColor(.gray)
                        TextEditor(text: $translationTr)
                            .frame(height: 100)
                            .cornerRadius(4)
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Key Points (comma separated)").font(.caption).foregroundColor(.gray)
                        TextField("e.g. FastAPI, Scale, SEO", text: $keyPointsStr)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    let keyPoints = keyPointsStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let newItem = VaultInterviewItem(
                        id: item?.id ?? UUID(),
                        question: question,
                        answerFinnish: answerFinnish,
                        translationTr: translationTr,
                        keyPoints: keyPoints
                    )
                    
                    if item == nil {
                        VaultService.shared.addItem(to: categoryID, item: newItem)
                    } else {
                        VaultService.shared.updateItem(in: categoryID, item: newItem)
                    }
                    dismiss()
                }
                .buttonStyle(.interactive)
            }
            .buttonStyle(.interactive)
        }
        .padding()
        .frame(width: 450, height: 600)
        .onAppear {
            if let item = item {
                question = item.question
                answerFinnish = item.answerFinnish
                translationTr = item.translationTr
                keyPointsStr = item.keyPoints.joined(separator: ", ")
            }
        }
        .preferredColorScheme(.dark)
    }
}

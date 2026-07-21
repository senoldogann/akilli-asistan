import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
                HStack(spacing: 12) {
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
                        .background(Color.glassFill)
                        .cornerRadius(20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(Color.glassStroke, lineWidth: 0.5)
                        )
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
                        .background(Color.glassFill)
                        .cornerRadius(20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(Color.glassStroke, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.interactive)
                    .pointerCursor()
                    
                    Button(action: dismissSafely) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(Color.textSecondary)
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.interactive)
                    .pointerCursor()
                    .padding(.leading, 8)
                }
                .padding(20)
                .background(Color.black.opacity(0.12))
                .overlay(
                    Rectangle()
                        .frame(height: 0.8)
                        .foregroundColor(Color.glassStroke),
                    alignment: .bottom
                )
                
                if let warmUpFeedback {
                    Text(warmUpFeedback)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(warmUpFeedbackIsWarning ? .orange : .green)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
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
                            .background(Color.orange.opacity(0.08))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.8)
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
        .frame(minWidth: 450, idealWidth: 600, maxWidth: 900, minHeight: 400, idealHeight: 650, maxHeight: 1000)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.75)
            }
        )
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.glassStroke, lineWidth: 0.8)
        )
        .shadow(color: Color.glassShadow, radius: 30, x: 0, y: 10)
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
                    .font(.system(.body, design: .rounded))
                    .foregroundColor(.white)

                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.glassFill)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.glassStroke, lineWidth: 0.8)
            )
        }
    }
    
    func triggerWarmUp() {
        warmUpFeedbackTask?.cancel()
        warmUpFeedback = "Vectorizing active JD & Vault context..."
        warmUpFeedbackIsWarning = false
        
        warmUpFeedbackTask = Task {
            let result = onWarmUp?() ?? "No context index created."
            await MainActor.run {
                if result.contains("Warning") || result.contains("No job description") {
                    warmUpFeedbackIsWarning = true
                }
                warmUpFeedback = result
            }
            
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await MainActor.run {
                if !Task.isCancelled {
                    withAnimation {
                        warmUpFeedback = nil
                    }
                }
            }
        }
    }
    
    func refreshSearchIndex() {
        searchIndex = VaultSearchEngine.makeIndex(categories: vaultService.categories)
    }
    
    func handleSearchChange(_ query: String, proxy: ScrollViewProxy) {
        searchTask?.cancel()
        
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            highlightedCategoryID = nil
            highlightedItemID = nil
            return
        }
        
        searchTask = Task {
            let results = VaultSearchEngine.rankedResults(query: query, index: searchIndex)
            await MainActor.run {
                self.searchResults = results
                if let bestMatch = results.first {
                    highlightedCategoryID = bestMatch.categoryID
                    highlightedItemID = bestMatch.itemID
                    
                    withAnimation(.spring(response: 0.35)) {
                        expandedCategory = bestMatch.categoryID
                    }
                    
                    if lastAutoFocusedResultID != bestMatch.id {
                        lastAutoFocusedResultID = bestMatch.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.spring(response: 0.3)) {
                                proxy.scrollTo(bestMatch.itemID, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }
    
    func dismissSafely() {
        isClosing = true
        withAnimation(.easeOut(duration: 0.16)) {
            isPresented = false
        }
    }
    
    func importVault() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.message = "Select vault backup file (JSON)"
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                _ = try vaultService.importVault(from: url, strategy: .mergeExisting)
            } catch {
                print("Failed to import vault: \(error.localizedDescription)")
            }
        }
    }
    
    func exportVault() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "zerolose_vault.json"
        panel.message = "Export vault backup (JSON)"
        
        if panel.runModal() == .OK, let url = panel.url {
            if let data = try? JSONEncoder().encode(vaultService.categories) {
                try? data.write(to: url)
            }
        }
    }
}

// MARK: - Category View

struct CategoryView: View {
    let category: VaultInterviewCategory
    let isExpanded: Bool
    let isSearchMatch: Bool
    let highlightedItemID: UUID?
    
    var onTap: () -> Void
    var onAddItem: () -> Void
    var onDelete: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: category.icon)
                    .font(.title3)
                    .foregroundColor(isSearchMatch ? .orange : .white.opacity(0.85))
                    .frame(width: 24)
                
                Text(category.title)
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text("\(category.items.count) q&a")
                    .font(.caption)
                    .foregroundColor(Color.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.glassFill)
                    .cornerRadius(4)
                
                Spacer()
                
                HStack(spacing: 12) {
                    Button(action: onAddItem) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 15))
                            .foregroundColor(.orange)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundColor(.red.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    
                    Image(systemName: "chevron.right")
                        .foregroundColor(Color.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .padding(16)
            .background(Color.black.opacity(0.15))
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
        .background(isSearchMatch ? Color.orange.opacity(0.08) : Color.glassFill)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isSearchMatch
                    ? Color.orange.opacity(0.4)
                    : Color.glassStroke,
                    lineWidth: 0.8
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
                    .font(.system(size: CGFloat(fontSize), weight: .bold, design: fontDesign))
                    .foregroundColor(Color.textPrimary)
                    .multilineTextAlignment(.leading)
                
                Spacer()
                
                HStack(spacing: 12) {
                    Button(action: {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("EditVaultItem"),
                            object: nil,
                            userInfo: ["categoryID": categoryID, "item": item]
                        )
                    }) {
                        Image(systemName: "pencil")
                            .foregroundColor(.blue.opacity(0.7))
                    }
                    .buttonStyle(.interactive)
                    .pointerCursor()
                    
                    Button(action: {
                        vaultService.deleteItem(from: categoryID, itemID: item.id)
                    }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red.opacity(0.6))
                    }
                    .buttonStyle(.interactive)
                    .pointerCursor()
                }
            }
            
            // Answer Content (Always Visible)
            VStack(alignment: .leading, spacing: 8) {
                Text(item.answerFinnish)
                    .font(.system(size: CGFloat(fontSize), design: fontDesign))
                    .help(item.translationTr)
                    .foregroundColor(Color.textPrimary.opacity(0.9))
                    .lineSpacing(4)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.04))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.orange.opacity(0.14), lineWidth: 0.8)
                    )
                
                HStack(spacing: 6) {
                    ForEach(item.keyPoints, id: \.self) { point in
                        Text(point)
                            .font(.system(size: CGFloat(fontSize) - 4, design: .rounded))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(6)
                    }
                }
            }
            .padding(12)
            .background(isSearchMatch ? Color.orange.opacity(0.05) : Color.clear)
            .cornerRadius(10)
        }
        .padding(16)
        .background(Color.black.opacity(0.08))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color.glassStroke),
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
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            
            TextField("Category Title", text: $title)
                .textFieldStyle(.plain)
                .padding(8)
                .background(Color.black.opacity(0.18))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.glassStroke, lineWidth: 0.8))
            
            TextField("SF Symbol Icon Name", text: $icon)
                .textFieldStyle(.plain)
                .padding(8)
                .background(Color.black.opacity(0.18))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.glassStroke, lineWidth: 0.8))
            
            HStack {
                Button("Cancel") { isPresented = false }
                    .foregroundColor(Color.textSecondary)
                Spacer()
                Button("Add") {
                    VaultService.shared.addCategory(VaultInterviewCategory(title: title, icon: icon, items: []))
                    isPresented = false
                }
                .foregroundColor(.orange)
            }
            .buttonStyle(.interactive)
        }
        .padding()
        .frame(width: 300)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.glassStroke, lineWidth: 0.8))
        .preferredColorScheme(.dark)
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
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            
            ScrollView {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Question").font(.caption).foregroundColor(Color.textSecondary)
                        TextEditor(text: $question)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(Color.black.opacity(0.18))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.glassStroke, lineWidth: 0.8))
                            .frame(height: 60)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Answer (Finnish)").font(.caption).foregroundColor(Color.textSecondary)
                        TextEditor(text: $answerFinnish)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(Color.black.opacity(0.18))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.glassStroke, lineWidth: 0.8))
                            .frame(height: 100)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Translation / Search Alias").font(.caption).foregroundColor(Color.textSecondary)
                        TextEditor(text: $translationTr)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(Color.black.opacity(0.18))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.glassStroke, lineWidth: 0.8))
                            .frame(height: 100)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Key Points (comma separated)").font(.caption).foregroundColor(Color.textSecondary)
                        TextField("e.g. FastAPI, Scale, SEO", text: $keyPointsStr)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(Color.black.opacity(0.18))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.glassStroke, lineWidth: 0.8))
                    }
                }
            }
            
            HStack {
                Button("Cancel") { dismiss() }
                    .foregroundColor(Color.textSecondary)
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
                .foregroundColor(.orange)
            }
            .buttonStyle(.interactive)
        }
        .padding()
        .frame(width: 450, height: 600)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.glassStroke, lineWidth: 0.8))
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

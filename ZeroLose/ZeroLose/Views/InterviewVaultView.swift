import SwiftUI
// InterviewVaultView.swift - Updated to use VaultService

struct InterviewVaultView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var vaultService = VaultService.shared
    @State private var expandedCategory: UUID? = nil
    @State private var isClosing = false
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
        VStack(spacing: 0) {
            // Header
            HStack {
                ZeroLoseIcon(type: .book, color: .orange, size: 22)
                Text("Smindle Interview Vault")
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
                    }
                }
                .padding(20)
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
    func triggerWarmUp() {
        let totalItems = vaultService.categories.reduce(0) { $0 + $1.items.count }
        let fallbackMessage = totalItems > 0
            ? "🔥 Interview context yüklendi (\(totalItems) soru)."
            : "⚠️ Vault boş. Sadece temel interview context yüklendi."
        
        let message = onWarmUp?() ?? fallbackMessage
        warmUpFeedbackTask?.cancel()
        warmUpFeedback = message
        warmUpFeedbackIsWarning = message.hasPrefix("⚠️")
        
        warmUpFeedbackTask = Task {
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
            await MainActor.run {
                self.warmUpFeedback = nil
                self.warmUpFeedbackIsWarning = false
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
                        ItemView(item: item, categoryID: category.id)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.black.opacity(0.2))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(isExpanded ? 0.1 : 0.05), lineWidth: 1)
        )
    }
}

struct ItemView: View {
    let item: VaultInterviewItem
    let categoryID: UUID
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
                    // Tooltip for Turkish translation
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
                        Text("Translation (Turkish)").font(.caption).foregroundColor(.gray)
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

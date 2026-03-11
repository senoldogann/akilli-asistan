import SwiftUI

struct CheatSheetView: View {
    @State private var viewModel: CheatSheetViewModel
    @Binding var isPresented: Bool
    
    init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
        let ollamaService = OllamaService()
        let intelligenceService = IntelligenceService(ollamaService: ollamaService)
        self._viewModel = State(initialValue: CheatSheetViewModel(intelligenceService: intelligenceService))
    }
    
    // Theme helper
    @AppStorage("selectedThemeName") private var selectedTheme: String = "Red"
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
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                ZeroLoseIcon(type: .book, color: themeColor, size: 18)
                Text("TECH PREP VAULT (Huutokaupat.fi)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                
                Spacer()
                
                // Warm-up Button
                if !viewModel.isWarmingUp {
                    Button(action: {
                        Task {
                            await viewModel.startWarmup()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Text("⚡")
                            Text("Warm-up")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(Color.orange.opacity(0.8))
                        .cornerRadius(12)
                    }
                    .buttonStyle(.interactive)
                    .pointerCursor()
                    .help("Pre-cache all answers for instant responses")
                } else {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(.orange)
                        Text(viewModel.warmupProgress)
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                }
                
                Button(action: { withAnimation { isPresented = false } }) {
                    ZeroLoseIcon(type: .xmark, color: .white.opacity(0.4), size: 14)
                }
                .buttonStyle(.interactive)
                .pointerCursor()
            }
            .padding(16)
            .background(Color.white.opacity(0.03))
            
            // Search & Filter Bar
            VStack(spacing: 12) {
                // Search Field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.white.opacity(0.4))
                        .font(.system(size: 14))
                    
                    TextField("Search topics (e.g., 'React', 'Scale')...", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .font(.system(size: 13))
                }
                .padding(10)
                .background(Color.black.opacity(0.3))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
                
                // Category Tags
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        CategoryTag(title: "All", isSelected: viewModel.selectedCategory == nil, color: themeColor) {
                            viewModel.selectedCategory = nil
                        }
                        
                        ForEach(viewModel.categories, id: \.self) { category in
                            CategoryTag(title: category, isSelected: viewModel.selectedCategory == category, color: themeColor) {
                                viewModel.selectedCategory = category
                            }
                        }
                    }
                }
            }
            .padding(16)
            
            Divider().background(Color.white.opacity(0.1))
            
            // Content List
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if viewModel.filteredItems.isEmpty {
                        Text("No matches found.")
                            .foregroundColor(.white.opacity(0.4))
                            .font(.system(size: 13))
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        ForEach(viewModel.filteredItems) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(item.category)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(themeColor)
                                        .padding(.vertical, 2)
                                        .padding(.horizontal, 6)
                                        .background(themeColor.opacity(0.1))
                                        .cornerRadius(4)
                                    Spacer()
                                }
                                
                                Text(item.question)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                
                                Text(item.answer)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundColor(.white.opacity(0.8))
                                    .lineSpacing(4)
                            }
                            .padding(16)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 450, height: 600)
        .background(Color.zeroBackground)
        .preferredColorScheme(.dark)
    }
}

struct CategoryTag: View {
    let title: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? .white : .white.opacity(0.6))
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(isSelected ? color : Color.white.opacity(0.05))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(isSelected ? color : Color.white.opacity(0.1), lineWidth: 1)
                )
        }
        .buttonStyle(.interactive)
        .pointerCursor()
    }
}

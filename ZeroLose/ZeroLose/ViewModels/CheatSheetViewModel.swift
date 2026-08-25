import Foundation
import Combine
import os

class CheatSheetViewModel: ObservableObject {
    @Published var items: [InterviewItem] = []
    @Published var filteredItems: [InterviewItem] = []
    @Published var searchText: String = ""
    @Published var selectedCategory: String? = nil
    @Published var isWarmingUp: Bool = false
    @Published var warmupProgress: String = ""
    
    // Veriden benzersiz kategoriler
    var categories: [String] {
        Array(Set(items.map { $0.category })).sorted()
    }
    
    private var cancellables = Set<AnyCancellable>()
    private let cacheService = ResponseCacheService()
    private let intelligenceService: IntelligenceService
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.zerolose", category: "CheatSheetViewModel")
    
    init(intelligenceService: IntelligenceService) {
        self.intelligenceService = intelligenceService
        loadData()
        
        // Tepkisel arama ve filtre
        $searchText
            .combineLatest($selectedCategory)
            .sink { [weak self] (query, category) in
                self?.filterData(query: query, category: category)
            }
            .store(in: &cancellables)
    }
    
    private func loadData() {
        guard let url = Bundle.main.url(forResource: "InterviewData", withExtension: "json") else {
            logger.error("InterviewData.json not found")
            return
        }
        
        do {
            let data = try Data(contentsOf: url)
            self.items = try JSONDecoder().decode([InterviewItem].self, from: data)
            self.filteredItems = self.items
        } catch {
            logger.error("Error decoding InterviewData.json: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    private func filterData(query: String, category: String?) {
        var results = items
        
        // Kategori Filtresi
        if let category = category {
            results = results.filter { $0.category == category }
        }
        
        // Arama Filtresi
        if !query.isEmpty {
            results = results.filter { item in
                item.question.localizedCaseInsensitiveContains(query) ||
                item.answer.localizedCaseInsensitiveContains(query) ||
                item.category.localizedCaseInsensitiveContains(query)
            }
        }
        
        self.filteredItems = results
    }
    
    // MARK: - Isınma Modu
    
    func startWarmup() async {
        await MainActor.run { isWarmingUp = true }
        
        // 1. Güncel veri özetini hesapla
        let currentHash = calculateDataHash(from: items)
        
        // 2. Önbelleği doğrula (Otomatik geçersiz kılma)
        if !cacheService.validateCache(against: currentHash) {
            await MainActor.run { warmupProgress = "Cache outdated. Clearing..." }
            cacheService.clearCache()
        }
        
        // 3. Tüm soruları ısıt
        for (index, item) in items.enumerated() {
            await MainActor.run {
                warmupProgress = "Processing \(index + 1)/\(items.count): \(item.category)"
            }
            
            do {
                var fullAnswer = ""
                let processedResponse = try await intelligenceService.process(
                    query: item.question,
                    imageData: nil,
                    onStatusUpdate: { _ in },
                    onPartialResponse: { partial in
                        fullAnswer = partial
                    }
                )
                fullAnswer = processedResponse.text
                
                // Önbelleğe kaydet
                cacheService.saveResponse(
                    question: item.question,
                    answer: fullAnswer,
                    category: item.category
                )
            } catch {
                logger.error("Warmup failed for category \(item.category, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        
        // 4. Özeti kaydet
        cacheService.saveSourceHash(currentHash)
        
        await MainActor.run {
            warmupProgress = "Complete! ✅ (\(items.count) answers cached)"
            isWarmingUp = false
        }
    }
    
    private func calculateDataHash(from items: [InterviewItem]) -> String {
        let combined = items.map { $0.question + $0.answer + $0.category }.joined()
        return combined.sha256()
    }
}

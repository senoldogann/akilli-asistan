import Foundation
import Combine
import os

struct VaultInterviewItem: Identifiable, Codable {
    var id: UUID = UUID()
    var question: String
    var answerFinnish: String
    var translationTr: String
    var keyPoints: [String]
}

struct VaultInterviewCategory: Identifiable, Codable {
    var id: UUID = UUID()
    var title: String
    var icon: String
    var items: [VaultInterviewItem]
}

class VaultService: ObservableObject {
    static let shared = VaultService()
    
    @Published var categories: [VaultInterviewCategory] = []
    private let logger = Logger(subsystem: "com.senoldogan.ZeroLose", category: "VaultService")
    
    private var fileURL: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupportDir = paths[0].appendingPathComponent("ZeroLose", isDirectory: true)
        
        // Ensure directory exists
        if !FileManager.default.fileExists(atPath: appSupportDir.path) {
            try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        }
        
        return appSupportDir.appendingPathComponent("interview_vault.json")
    }
    
    private init() {
        load()
    }
    
    func save() {
        do {
            let data = try JSONEncoder().encode(categories)
            try data.write(to: fileURL)
            logger.info("✅ Vault saved to \(self.fileURL.path)")
        } catch {
            logger.error("❌ Failed to save vault: \(error.localizedDescription)")
        }
    }
    
    func load() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                categories = try JSONDecoder().decode([VaultInterviewCategory].self, from: data)
                logger.info("✅ Vault loaded with \(self.categories.count) categories")
            } catch {
                logger.error("❌ Failed to load vault: \(error.localizedDescription)")
                loadDefaultData()
            }
        } else {
            loadDefaultData()
        }
    }
    
    private func loadDefaultData() {
        // Fallback to original hardcoded data
        categories = [
            VaultInterviewCategory(
                title: "Intro & Experience",
                icon: "person.fill",
                items: [
                    VaultInterviewItem(
                        question: "Giriş: 'Öğrenci değilim, Profesionelim'",
                        answerFinnish: "Olen Senol ja mulla on tosiaankin yli seitsemän vuoden kokemus ohjelmistokehityksestä. Vaikka opintoni Oulussa ovat paperilla kesken, olen tehnyt tätä työtä ammatikseni jo pitkään. Olen erikoistunut React-ekosysteemiin ja vaativiin web-sovelluksiin. En siis hae harjoittelupaikkaa, vaan roolia, jossa voin ottaa vastuuta arkkitehtuurista heti ensimmäisestä päivästä alkaen.",
                        translationTr: "Evet, yani ben Senol. Gerçekten yedi yılı aşkın yazılım geliştirme deneyimim var. Kağıt üzerinde Oulu'da eğitimim devam ediyor gibi görünse de, bu işi uzun süredir profesyonel olarak yapıyorum. React ekosistemi ve zorlu web uygulamaları konusunda uzmanlaştım. Yani staj yeri aramıyorum, ilk günden itibaren mimari sorumluluk alabileceğim bir rol arıyorum.",
                        keyPoints: ["Not a student", "7+ years exp", "Architectural Ownership"]
                    )
                ]
            )
            // ... more default items can be added here
        ]
        save()
    }
    
    // CRUD Operations
    func addCategory(_ category: VaultInterviewCategory) {
        categories.append(category)
        save()
    }
    
    func deleteCategory(id: UUID) {
        categories.removeAll { $0.id == id }
        save()
    }
    
    func updateItem(in categoryID: UUID, item: VaultInterviewItem) {
        if let catIndex = categories.firstIndex(where: { $0.id == categoryID }) {
            if let itemIndex = categories[catIndex].items.firstIndex(where: { $0.id == item.id }) {
                categories[catIndex].items[itemIndex] = item
                save()
            }
        }
    }
    
    func addItem(to categoryID: UUID, item: VaultInterviewItem) {
        if let index = categories.firstIndex(where: { $0.id == categoryID }) {
            categories[index].items.append(item)
            save()
        }
    }
    
    func deleteItem(from categoryID: UUID, itemID: UUID) {
        if let index = categories.firstIndex(where: { $0.id == categoryID }) {
            categories[index].items.removeAll { $0.id == itemID }
            save()
        }
    }
}

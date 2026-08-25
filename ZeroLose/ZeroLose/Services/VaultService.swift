import Foundation
import Combine
import os

struct VaultInterviewItem: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var question: String
    var answerFinnish: String
    var translationTr: String
    var keyPoints: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case question
        case answerFinnish
        case translationTr
        case keyPoints
    }

    init(
        id: UUID = UUID(),
        question: String,
        answerFinnish: String,
        translationTr: String,
        keyPoints: [String]
    ) {
        self.id = id
        self.question = question
        self.answerFinnish = answerFinnish
        self.translationTr = translationTr
        self.keyPoints = keyPoints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try? container.decode(UUID.self, forKey: .id)
        let decodedIDString = try? container.decode(String.self, forKey: .id)
        self.id = decodedID ?? decodedIDString.flatMap(UUID.init(uuidString:)) ?? UUID()
        self.question = try container.decode(String.self, forKey: .question)
        self.answerFinnish = try container.decode(String.self, forKey: .answerFinnish)
        self.translationTr = try container.decodeIfPresent(String.self, forKey: .translationTr) ?? ""
        self.keyPoints = try container.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
    }
}

struct VaultInterviewCategory: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var title: String
    var icon: String
    var items: [VaultInterviewItem]

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case icon
        case items
    }

    init(
        id: UUID = UUID(),
        title: String,
        icon: String,
        items: [VaultInterviewItem]
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try? container.decode(UUID.self, forKey: .id)
        let decodedIDString = try? container.decode(String.self, forKey: .id)
        self.id = decodedID ?? decodedIDString.flatMap(UUID.init(uuidString:)) ?? UUID()
        self.title = try container.decode(String.self, forKey: .title)
        self.icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "folder.fill"
        self.items = try container.decodeIfPresent([VaultInterviewItem].self, forKey: .items) ?? []
    }
}

struct VaultExportSnapshot: Codable, Sendable {
    let exportedAt: Date
    let totalCategories: Int
    let totalQuestions: Int
    let categories: [VaultInterviewCategory]
}

private struct VaultImportEnvelope: Decodable {
    let categories: [VaultInterviewCategory]
}

enum VaultImportStrategy: Sendable {
    case replaceExisting
    case mergeExisting
}

struct VaultImportSummary: Sendable {
    let totalCategories: Int
    let totalQuestions: Int
}

enum VaultImportError: LocalizedError {
    case unsupportedFormat
    case emptyVault

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "The selected file is not a supported Interview Vault JSON export."
        case .emptyVault:
            return "The selected file does not contain any valid vault questions."
        }
    }
}

class VaultService: ObservableObject {
    static let shared = VaultService()
    
    @Published var categories: [VaultInterviewCategory] = []
    private let logger = Logger(subsystem: "com.senoldogan.ZeroLose", category: "VaultService")
    
    private var fileURL: URL {
        let appSupportBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let appSupportDir = appSupportBase.appendingPathComponent("ZeroLose", isDirectory: true)
        
        // Dizinin var olduğundan emin ol
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
        // İlk başlatmada boş başla. Açık kaynak derlemeler kişisel mülakat verisi beslememeli.
        categories = []
        save()
    }
    
    // CRUD İşlemleri
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

    static func exportSnapshot(
        for categories: [VaultInterviewCategory],
        exportedAt: Date = Date()
    ) -> VaultExportSnapshot {
        VaultExportSnapshot(
            exportedAt: exportedAt,
            totalCategories: categories.count,
            totalQuestions: categories.reduce(0) { $0 + $1.items.count },
            categories: categories
        )
    }

    static func exportData(
        for categories: [VaultInterviewCategory],
        exportedAt: Date = Date()
    ) throws -> Data {
        let snapshot = exportSnapshot(for: categories, exportedAt: exportedAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    func exportCurrentVault() throws -> Data {
        try Self.exportData(for: categories)
    }

    func exportCurrentVault(to url: URL) throws {
        let data = try exportCurrentVault()
        try data.write(to: url, options: .atomic)
    }

    static func importCategories(from data: Data) throws -> [VaultInterviewCategory] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let importedCategories: [VaultInterviewCategory]
        if let snapshot = try? decoder.decode(VaultExportSnapshot.self, from: data) {
            importedCategories = snapshot.categories
        } else if let envelope = try? decoder.decode(VaultImportEnvelope.self, from: data) {
            importedCategories = envelope.categories
        } else if let categories = try? decoder.decode([VaultInterviewCategory].self, from: data) {
            importedCategories = categories
        } else {
            throw VaultImportError.unsupportedFormat
        }

        let sanitized = sanitizedImportedCategories(importedCategories)
        guard sanitized.contains(where: { !$0.items.isEmpty }) else {
            throw VaultImportError.emptyVault
        }
        return sanitized
    }

    static func mergeCategories(
        existing: [VaultInterviewCategory],
        imported: [VaultInterviewCategory]
    ) -> [VaultInterviewCategory] {
        let sanitizedImported = sanitizedImportedCategories(imported)
        var merged = existing
        var categoryIndexByKey: [String: Int] = [:]
        for (index, category) in merged.enumerated() {
            categoryIndexByKey[normalizedImportKey(category.title)] = index
        }

        for importedCategory in sanitizedImported {
            let key = normalizedImportKey(importedCategory.title)
            if let existingIndex = categoryIndexByKey[key] {
                merged[existingIndex] = mergeCategory(existing: merged[existingIndex], imported: importedCategory)
            } else {
                merged.append(importedCategory)
                categoryIndexByKey[key] = merged.count - 1
            }
        }

        return merged
    }

    func importVault(from url: URL, strategy: VaultImportStrategy) throws -> VaultImportSummary {
        let data = try Data(contentsOf: url)
        let importedCategories = try Self.importCategories(from: data)

        switch strategy {
        case .replaceExisting:
            categories = importedCategories
        case .mergeExisting:
            categories = Self.mergeCategories(existing: categories, imported: importedCategories)
        }

        save()
        return VaultImportSummary(
            totalCategories: categories.count,
            totalQuestions: categories.reduce(0) { $0 + $1.items.count }
        )
    }

    private static func sanitizedImportedCategories(_ categories: [VaultInterviewCategory]) -> [VaultInterviewCategory] {
        var sanitized: [VaultInterviewCategory] = []
        var categoryIndexByKey: [String: Int] = [:]

        for category in categories {
            let title = category.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            let cleanedCategory = VaultInterviewCategory(
                id: UUID(),
                title: title,
                icon: category.icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "folder.fill"
                    : category.icon.trimmingCharacters(in: .whitespacesAndNewlines),
                items: sanitizedImportedItems(category.items)
            )

            let key = normalizedImportKey(title)
            if let existingIndex = categoryIndexByKey[key] {
                sanitized[existingIndex] = mergeCategory(existing: sanitized[existingIndex], imported: cleanedCategory)
            } else {
                sanitized.append(cleanedCategory)
                categoryIndexByKey[key] = sanitized.count - 1
            }
        }

        return sanitized
    }

    private static func sanitizedImportedItems(_ items: [VaultInterviewItem]) -> [VaultInterviewItem] {
        var sanitized: [VaultInterviewItem] = []
        var itemIndexByKey: [String: Int] = [:]

        for item in items {
            let question = item.question.trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = item.answerFinnish.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty, !answer.isEmpty else { continue }

            let sanitizedItem = VaultInterviewItem(
                id: UUID(),
                question: question,
                answerFinnish: answer,
                translationTr: item.translationTr.trimmingCharacters(in: .whitespacesAndNewlines),
                keyPoints: item.keyPoints
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )

            let key = normalizedImportKey(question)
            if let existingIndex = itemIndexByKey[key] {
                sanitized[existingIndex] = mergedItem(
                    replacing: sanitized[existingIndex],
                    with: sanitizedItem
                )
            } else {
                sanitized.append(sanitizedItem)
                itemIndexByKey[key] = sanitized.count - 1
            }
        }

        return sanitized
    }

    private static func mergeCategory(
        existing: VaultInterviewCategory,
        imported: VaultInterviewCategory
    ) -> VaultInterviewCategory {
        var mergedItems = existing.items
        var itemIndexByKey: [String: Int] = [:]
        for (index, item) in mergedItems.enumerated() {
            itemIndexByKey[normalizedImportKey(item.question)] = index
        }

        for importedItem in imported.items {
            let key = normalizedImportKey(importedItem.question)
            if let existingIndex = itemIndexByKey[key] {
                mergedItems[existingIndex] = mergedItem(
                    replacing: mergedItems[existingIndex],
                    with: importedItem
                )
            } else {
                mergedItems.append(importedItem)
                itemIndexByKey[key] = mergedItems.count - 1
            }
        }

        let mergedIcon = imported.icon.isEmpty ? existing.icon : imported.icon
        return VaultInterviewCategory(
            id: existing.id,
            title: existing.title,
            icon: mergedIcon,
            items: mergedItems
        )
    }

    private static func mergedItem(
        replacing existing: VaultInterviewItem,
        with imported: VaultInterviewItem
    ) -> VaultInterviewItem {
        VaultInterviewItem(
            id: existing.id,
            question: imported.question,
            answerFinnish: imported.answerFinnish,
            translationTr: imported.translationTr,
            keyPoints: imported.keyPoints
        )
    }

    private static func normalizedImportKey(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

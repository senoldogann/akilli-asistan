import Foundation
import Security
import os

/// API key storage backed by Keychain.
struct Secrets: @unchecked Sendable {
    nonisolated private static let logger = Logger(subsystem: "com.zerolose", category: "secrets")

    nonisolated private static let legacyOllamaKeyStorage = "stored_ollama_api_key"
    nonisolated private static let legacyGroqKeyStorage = "stored_groq_api_key"
    nonisolated private static let legacyTavilyKeyStorage = "stored_tavily_api_key"
    nonisolated private static let legacyOpenAIKeyStorage = "stored_openai_api_key"
    nonisolated private static let migrationFlagStorage = "secrets_keychain_migration_v1"
    nonisolated private static let openAIPreferenceStorage = "prefer_openai_provider"

    nonisolated private static let ollamaAccount = "ollama_api_key"
    nonisolated private static let groqAccount = "groq_api_key"
    nonisolated private static let tavilyAccount = "tavily_api_key"
    nonisolated private static let openAIAccount = "openai_api_key"
    nonisolated private static let keychainService = Bundle.main.bundleIdentifier ?? "com.zerolose"

    // MARK: - API Keys

    nonisolated(unsafe) static var ollamaApiKey: String {
        get {
            migrateFromUserDefaultsIfNeeded()
            return readKeychainValue(account: ollamaAccount) ?? ""
        }
        set {
            migrateFromUserDefaultsIfNeeded()
            writeKeychainValue(newValue, account: ollamaAccount)
        }
    }

    nonisolated(unsafe) static var groqApiKey: String {
        get {
            migrateFromUserDefaultsIfNeeded()
            return readKeychainValue(account: groqAccount) ?? ""
        }
        set {
            migrateFromUserDefaultsIfNeeded()
            writeKeychainValue(newValue, account: groqAccount)
        }
    }

    nonisolated(unsafe) static var tavilyApiKey: String {
        get {
            migrateFromUserDefaultsIfNeeded()
            return readKeychainValue(account: tavilyAccount) ?? ""
        }
        set {
            migrateFromUserDefaultsIfNeeded()
            writeKeychainValue(newValue, account: tavilyAccount)
        }
    }

    nonisolated(unsafe) static var openAIApiKey: String {
        get {
            migrateFromUserDefaultsIfNeeded()
            return readKeychainValue(account: openAIAccount) ?? ""
        }
        set {
            migrateFromUserDefaultsIfNeeded()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed.hasPrefix("sk-") && !trimmed.isEmpty, forKey: openAIPreferenceStorage)
            writeKeychainValue(trimmed, account: openAIAccount)
        }
    }

    // MARK: - Validation

    nonisolated(unsafe) static var isOllamaKeyValid: Bool {
        let value = ollamaApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.count > 10
    }

    nonisolated(unsafe) static var isGroqKeyValid: Bool {
        let value = groqApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.hasPrefix("gsk_")
    }

    nonisolated(unsafe) static var isTavilyKeyValid: Bool {
        let value = tavilyApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.hasPrefix("tvly-")
    }

    nonisolated(unsafe) static var isOpenAIKeyValid: Bool {
        migrateFromUserDefaultsIfNeeded()
        return UserDefaults.standard.bool(forKey: openAIPreferenceStorage)
    }

    // MARK: - Reset

    /// Compatibility method used by settings screen.
    /// It now clears stored keys instead of restoring embedded defaults.
    nonisolated static func resetToDefaults() {
        clearAll()
    }

    nonisolated static func clearAll() {
        UserDefaults.standard.set(false, forKey: openAIPreferenceStorage)
        deleteKeychainValue(account: ollamaAccount)
        deleteKeychainValue(account: groqAccount)
        deleteKeychainValue(account: tavilyAccount)
        deleteKeychainValue(account: openAIAccount)
    }

    // MARK: - Migration

    nonisolated static func migrateFromUserDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationFlagStorage) else { return }

        migrateLegacyKey(defaults: defaults, legacyKey: legacyOllamaKeyStorage, account: ollamaAccount)
        migrateLegacyKey(defaults: defaults, legacyKey: legacyGroqKeyStorage, account: groqAccount)
        migrateLegacyKey(defaults: defaults, legacyKey: legacyTavilyKeyStorage, account: tavilyAccount)
        migrateLegacyKey(defaults: defaults, legacyKey: legacyOpenAIKeyStorage, account: openAIAccount)
        if let legacyOpenAI = defaults.string(forKey: legacyOpenAIKeyStorage)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !legacyOpenAI.isEmpty {
            defaults.set(legacyOpenAI.hasPrefix("sk-"), forKey: openAIPreferenceStorage)
        }

        defaults.removeObject(forKey: legacyOllamaKeyStorage)
        defaults.removeObject(forKey: legacyGroqKeyStorage)
        defaults.removeObject(forKey: legacyTavilyKeyStorage)
        defaults.removeObject(forKey: legacyOpenAIKeyStorage)
        defaults.set(true, forKey: migrationFlagStorage)
    }

    nonisolated private static func migrateLegacyKey(defaults: UserDefaults, legacyKey: String, account: String) {
        guard let legacyValue = defaults.string(forKey: legacyKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !legacyValue.isEmpty else {
            return
        }

        guard readKeychainValue(account: account)?.isEmpty ?? true else { return }
        writeKeychainValue(legacyValue, account: account)
        logger.info("Migrated a legacy API key from UserDefaults to Keychain.")
    }

    // MARK: - Keychain

    nonisolated private static func readKeychainValue(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            logger.error("Failed to read key from Keychain. Status: \(status, privacy: .public)")
            return nil
        }
    }

    nonisolated private static func writeKeychainValue(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            deleteKeychainValue(account: account)
            return
        }

        guard let data = trimmed.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var itemToAdd = query
            itemToAdd[kSecValueData as String] = data
            itemToAdd[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let addStatus = SecItemAdd(itemToAdd as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                logger.error("Failed to write key to Keychain. Status: \(addStatus, privacy: .public)")
                return
            }
            return
        }

        guard updateStatus == errSecSuccess else {
            logger.error("Failed to update key in Keychain. Status: \(updateStatus, privacy: .public)")
            return
        }
    }

    nonisolated private static func deleteKeychainValue(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Failed to delete key from Keychain. Status: \(status, privacy: .public)")
        }
    }
}

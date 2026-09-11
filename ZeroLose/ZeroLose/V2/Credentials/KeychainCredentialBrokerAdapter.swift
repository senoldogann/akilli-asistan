import Foundation
import Security

actor KeychainCredentialBrokerAdapter: CredentialBrokering, OpenAIKeyStoring {
    private static let openAIKeyAccount = "openai_api_key"

    private let openAIKeyService: String
    private var revokedScopes: Set<CredentialScope> = []
    private var activeHandles: Set<CredentialHandle> = []

    init(openAIKeyService: String? = nil) {
        self.openAIKeyService = openAIKeyService
            ?? Bundle.main.bundleIdentifier
            ?? "com.zerolose"
    }

    func availability(for scope: CredentialScope) -> CredentialAvailability {
        guard !revokedScopes.contains(scope) else {
            return CredentialAvailability(scope: scope, available: false)
        }

        return CredentialAvailability(scope: scope, available: isCredentialPresent(for: scope))
    }

    func issueHandle(for scope: CredentialScope) throws -> CredentialHandle {
        guard !revokedScopes.contains(scope), isCredentialPresent(for: scope) else {
            throw CredentialBrokerError.scopeUnavailable(scope)
        }

        let handle = CredentialHandle(scope: scope)
        activeHandles.insert(handle)
        return handle
    }

    func revoke(scope: CredentialScope) {
        revokedScopes.insert(scope)
        activeHandles = Set(activeHandles.filter { $0.scope != scope })
    }

    func isValid(_ handle: CredentialHandle) -> Bool {
        !revokedScopes.contains(handle.scope)
            && isCredentialPresent(for: handle.scope)
            && activeHandles.contains(handle)
    }

    func hasKey() async -> Bool {
        guard let value = try? readOpenAIKey() else {
            return false
        }
        return !value.isEmpty
    }

    func withKey(
        _ operation: @escaping @Sendable (String) async throws -> Void
    ) async throws {
        guard let value = try readOpenAIKey(), !value.isEmpty else {
            throw OpenAIKeyStoreError.missingKey
        }
        try await operation(value)
    }

    func store(_ value: String) async throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenAIKeyStoreError.invalidKey
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw OpenAIKeyStoreError.invalidKey
        }

        let query = openAIKeyQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw OpenAIKeyStoreError.keychainFailure(status: updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw OpenAIKeyStoreError.keychainFailure(status: addStatus)
        }
    }

    func remove() async throws {
        let status = SecItemDelete(openAIKeyQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenAIKeyStoreError.keychainFailure(status: status)
        }
    }

    private func isCredentialPresent(for scope: CredentialScope) -> Bool {
        switch scope.rawValue {
        case "openai.responses", "openai.audio":
            return (try? readOpenAIKey())?.isEmpty == false
        case "groq.chat", "groq.audio":
            return Secrets.isGroqKeyValid
        case "tavily.search":
            return Secrets.isTavilyKeyValid
        case "deepseek.chat":
            return Secrets.isDeepSeekKeyValid
        case "opencode.zen":
            return Secrets.isOpenCodeZenKeyValid
        case "opencode.go":
            return Secrets.isOpenCodeGoKeyValid
        case "ollama.cloud":
            return Secrets.isOllamaKeyValid
        default:
            return false
        }
    }

    private func readOpenAIKey() throws -> String? {
        var query = openAIKeyQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard
                let data = item as? Data,
                let value = String(data: data, encoding: .utf8)
            else {
                throw OpenAIKeyStoreError.invalidKey
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case errSecItemNotFound:
            return nil
        default:
            throw OpenAIKeyStoreError.keychainFailure(status: status)
        }
    }

    private func openAIKeyQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: openAIKeyService,
            kSecAttrAccount as String: Self.openAIKeyAccount
        ]
    }
}

actor KeychainCredentialBrokerAdapter: CredentialBrokering {
    private var revokedScopes: Set<CredentialScope> = []
    private var activeHandles: Set<CredentialHandle> = []

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

    private func isCredentialPresent(for scope: CredentialScope) -> Bool {
        switch scope.rawValue {
        case "openai.responses", "openai.audio":
            return Secrets.isOpenAIKeyValid
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
}

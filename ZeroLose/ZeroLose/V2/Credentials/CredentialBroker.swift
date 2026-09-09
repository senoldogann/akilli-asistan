import Foundation

struct CredentialScope: Hashable, Codable, Sendable {
    let rawValue: String
}

struct CredentialAvailability: Sendable, Equatable {
    let scope: CredentialScope
    let available: Bool
}

struct CredentialHandle: Hashable, Sendable {
    fileprivate let id: UUID
    let scope: CredentialScope

    init(scope: CredentialScope) {
        self.id = UUID()
        self.scope = scope
    }
}

enum CredentialBrokerError: Error, Equatable {
    case scopeUnavailable(CredentialScope)
}

protocol CredentialBrokering: Sendable {
    func availability(for scope: CredentialScope) async -> CredentialAvailability
    func issueHandle(for scope: CredentialScope) async throws -> CredentialHandle
    func revoke(scope: CredentialScope) async
}

actor InMemoryCredentialBroker: CredentialBrokering {
    private var availableScopes: Set<CredentialScope>
    private var activeHandles: Set<CredentialHandle> = []

    init(scopes: Set<String> = []) {
        self.availableScopes = Set(scopes.map(CredentialScope.init(rawValue:)))
    }

    func availability(for scope: CredentialScope) -> CredentialAvailability {
        CredentialAvailability(scope: scope, available: availableScopes.contains(scope))
    }

    func issueHandle(for scope: CredentialScope) throws -> CredentialHandle {
        guard availableScopes.contains(scope) else {
            throw CredentialBrokerError.scopeUnavailable(scope)
        }

        let handle = CredentialHandle(scope: scope)
        activeHandles.insert(handle)
        return handle
    }

    func revoke(scope: CredentialScope) {
        availableScopes.remove(scope)
        activeHandles = Set(activeHandles.filter { $0.scope != scope })
    }

    func isValid(_ handle: CredentialHandle) -> Bool {
        availableScopes.contains(handle.scope) && activeHandles.contains(handle)
    }
}

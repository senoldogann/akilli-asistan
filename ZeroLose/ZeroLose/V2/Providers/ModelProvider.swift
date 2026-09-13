import Foundation

nonisolated struct ModelProviderID: Hashable, Sendable, Codable {
    let rawValue: String
}

nonisolated struct ModelSessionID: Hashable, Sendable, Codable {
    let rawValue: String
}

nonisolated enum ModelRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

/// A single conversation turn.
///
/// `images` carries JPEG payloads for vision-capable providers. It is empty for
/// ordinary text turns, so text-only providers and callers are unaffected.
nonisolated struct ModelMessage: Codable, Sendable, Equatable {
    let role: ModelRole
    let content: String
    let images: [Data]

    nonisolated init(role: ModelRole, content: String, images: [Data] = []) {
        self.role = role
        self.content = content
        self.images = images
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case images
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(ModelRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        images = try container.decodeIfPresent([Data].self, forKey: .images) ?? []
    }
}

nonisolated struct ModelToolSchema: Codable, Sendable, Equatable {
    let name: String
    let description: String
    let inputSchemaJSON: Data
}

nonisolated enum ResponseMode: String, Codable, Sendable {
    case text
    case json
}

nonisolated struct ModelCapabilities: OptionSet, Codable, Sendable, Equatable {
    let rawValue: UInt16

    init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    static let textStreaming = Self(rawValue: 1 << 0)
    static let vision = Self(rawValue: 1 << 1)
    static let structuredTools = Self(rawValue: 1 << 2)
    static let jsonOutput = Self(rawValue: 1 << 3)
    static let sessionResume = Self(rawValue: 1 << 4)
    static let reasoningControl = Self(rawValue: 1 << 5)
}

nonisolated struct ModelDescriptor: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let displayName: String
    let providerID: ModelProviderID
    let capabilities: ModelCapabilities
}

nonisolated struct ModelRequest: Sendable, Equatable {
    let sessionID: ModelSessionID
    let conversation: [ModelMessage]
    let modelID: String
    let tools: [ModelToolSchema]
    let responseMode: ResponseMode
}

nonisolated enum ModelEvent: Sendable, Equatable {
    case started
    case textDelta(String)
    case toolCall(name: String, argumentsJSON: Data)
    case completed
}

nonisolated enum ProviderAvailability: String, Sendable, Equatable {
    case ready
    case detected
    case notInstalled
    case loginRequired
    case configurationRequired
    case unavailable
    case unsupportedVersion
}

nonisolated struct ProviderStatus: Sendable, Equatable {
    let providerID: ModelProviderID
    let displayName: String
    let availability: ProviderAvailability
}

nonisolated enum ProviderError: Error, Sendable, Equatable {
    case providerUnavailable(providerID: ModelProviderID)
    case loginRequired(providerID: ModelProviderID)
    case configurationRequired(providerID: ModelProviderID)
    case unsupportedVersion(providerID: ModelProviderID)
    case processFailed(providerID: ModelProviderID, exitCode: Int32)
    case timeout(providerID: ModelProviderID)
    case cancelled(providerID: ModelProviderID)
    case malformedOutput(providerID: ModelProviderID)
    case quotaExhausted(providerID: ModelProviderID)
    case rateLimited(providerID: ModelProviderID)
    case invalidCredential(providerID: ModelProviderID)
}

nonisolated protocol ModelProvider: Sendable {
    var id: ModelProviderID { get }
    var displayName: String { get }
    var capabilities: ModelCapabilities { get }

    func status() async -> ProviderStatus
    func discoverModels() async throws -> [ModelDescriptor]
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error>
    func cancel(sessionID: ModelSessionID) async
}

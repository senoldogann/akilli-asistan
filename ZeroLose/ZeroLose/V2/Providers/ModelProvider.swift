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
    /// Reasoning-effort values this specific model accepts, in the order the
    /// provider publishes them. Empty means the model (or this build) has no
    /// verified effort control, and no effort is ever sent for it.
    let reasoningEfforts: [String]
    /// The effort the provider uses when nothing is chosen.
    let defaultReasoningEffort: String?

    nonisolated init(
        id: String,
        displayName: String,
        providerID: ModelProviderID,
        capabilities: ModelCapabilities,
        reasoningEfforts: [String] = [],
        defaultReasoningEffort: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.providerID = providerID
        self.capabilities = capabilities
        self.reasoningEfforts = reasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case providerID
        case capabilities
        case reasoningEfforts
        case defaultReasoningEffort
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        providerID = try container.decode(ModelProviderID.self, forKey: .providerID)
        capabilities = try container.decode(ModelCapabilities.self, forKey: .capabilities)
        reasoningEfforts = try container.decodeIfPresent(
            [String].self,
            forKey: .reasoningEfforts
        ) ?? []
        defaultReasoningEffort = try container.decodeIfPresent(
            String.self,
            forKey: .defaultReasoningEffort
        )
    }

    func supportsReasoningEffort(_ effort: String) -> Bool {
        reasoningEfforts.contains(effort)
    }
}

nonisolated struct ModelRequest: Sendable, Equatable {
    let sessionID: ModelSessionID
    let conversation: [ModelMessage]
    let modelID: String
    let tools: [ModelToolSchema]
    let responseMode: ResponseMode
    /// The reasoning effort bound to this request, already validated against the
    /// selected model's `reasoningEfforts` by the provider control plane.
    let reasoningEffort: String?

    nonisolated init(
        sessionID: ModelSessionID,
        conversation: [ModelMessage],
        modelID: String,
        tools: [ModelToolSchema],
        responseMode: ResponseMode,
        reasoningEffort: String? = nil
    ) {
        self.sessionID = sessionID
        self.conversation = conversation
        self.modelID = modelID
        self.tools = tools
        self.responseMode = responseMode
        self.reasoningEffort = reasoningEffort
    }
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
    /// The provider process reported its own failure (usage limit, auth problem,
    /// server error, …). The message is the provider's own text, already bounded
    /// and redacted by `reportedByProvider`; carrying it is the difference between
    /// an actionable error and an opaque enum case.
    case providerReported(providerID: ModelProviderID, message: String)
}

/// Bounds and redacts provider/CLI text before it is shown to a user or stored in
/// an error value.
///
/// Provider stderr and error payloads are untrusted: they can contain newlines,
/// terminal control characters, and credential-shaped tokens. Nothing here ever
/// returns material that looks like a bearer token or API key.
nonisolated enum ProviderDiagnosticText {
    static let maximumLength = 400

    private static let credentialPatterns = [
        #"(?i)\bBearer\s+\S+"#,
        #"\bsk-[A-Za-z0-9_-]{8,}"#,
        #"\bgsk_[A-Za-z0-9_-]{8,}"#,
        #"\btvly-[A-Za-z0-9_-]{8,}"#,
        #"\b[A-Za-z0-9_-]{48,}"#,
    ]

    static func sanitized(_ raw: String) -> String {
        var text = raw.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        text = text.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .reduce(into: String()) { $0.unicodeScalars.append($1) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        for pattern in credentialPatterns {
            text = text.replacingOccurrences(
                of: pattern,
                with: "<redacted>",
                options: .regularExpression
            )
        }

        guard text.count > maximumLength else { return text }
        return String(text.prefix(maximumLength)) + "…"
    }
}

extension ProviderError {
    /// The single entry point for surfacing text the provider itself produced, so
    /// untrusted provider output is always bounded and redacted first.
    nonisolated static func reportedByProvider(
        _ providerID: ModelProviderID,
        message: String
    ) -> ProviderError {
        let sanitized = ProviderDiagnosticText.sanitized(message)
        guard !sanitized.isEmpty else {
            return .malformedOutput(providerID: providerID)
        }
        return .providerReported(providerID: providerID, message: sanitized)
    }
}

extension ProviderError: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case .providerUnavailable(let providerID):
            return "\(Self.label(for: providerID)) is not available. Check that the CLI or credential is installed and reachable."
        case .loginRequired(let providerID):
            return "\(Self.label(for: providerID)) requires you to sign in."
        case .configurationRequired(let providerID):
            return "\(Self.label(for: providerID)) needs configuration before it can answer."
        case .unsupportedVersion(let providerID):
            return "\(Self.label(for: providerID)) is an unsupported version."
        case .processFailed(let providerID, let exitCode):
            return "\(Self.label(for: providerID)) exited with status \(exitCode) before answering."
        case .timeout(let providerID):
            return "\(Self.label(for: providerID)) timed out before answering."
        case .cancelled:
            return "The response was stopped."
        case .malformedOutput(let providerID):
            return "\(Self.label(for: providerID)) returned output this build could not read."
        case .quotaExhausted(let providerID):
            return "\(Self.label(for: providerID)) reported that your quota or usage limit is exhausted."
        case .rateLimited(let providerID):
            return "\(Self.label(for: providerID)) is rate limited. Try again shortly."
        case .invalidCredential(let providerID):
            return "\(Self.label(for: providerID)) rejected the stored credential."
        case .providerReported(_, let message):
            return message
        }
    }

    private nonisolated static func label(for providerID: ModelProviderID) -> String {
        let raw = providerID.rawValue
        guard !raw.isEmpty else { return "The provider" }
        return raw.replacingOccurrences(of: "-", with: " ").capitalized
    }
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

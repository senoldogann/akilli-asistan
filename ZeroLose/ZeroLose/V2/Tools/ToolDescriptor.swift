import Foundation

struct ToolID: Hashable, Codable, Sendable {
    let rawValue: String
}

enum ToolConcurrencyClass: String, Codable, Sendable {
    case read
    case mutation
}

enum IdempotencySemantics: String, Codable, Sendable {
    case none
    case logicalOperationKeyRequired
    case providerNative
}

struct VerificationContract: Codable, Sendable, Equatable {
    let kind: String
}

struct ToolDescriptor: Sendable, Equatable {
    let id: ToolID
    let providerID: String
    let provenance: String
    let descriptorRevision: UInt64
    let schemaDigest: String
    let inputSchemaJSON: Data
    let outputSchemaJSON: Data?
    let effectClass: EffectClass
    let declaredRisk: RiskLevel
    let requiredCredentialScopes: Set<String>
    let idempotency: IdempotencySemantics
    let concurrencyClass: ToolConcurrencyClass
    let verificationContract: VerificationContract
    let enabled: Bool
}

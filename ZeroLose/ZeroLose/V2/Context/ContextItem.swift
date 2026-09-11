import Foundation

nonisolated enum ContextSourceKind: String, Codable, Sendable, Equatable {
    case conversation
    case memory
    case attachment
    case activeTask
    case runtimeEvidence
}

nonisolated enum ContextSensitivity: String, Codable, Sendable, Equatable {
    case normal
    case privateContent
    case credentialMaterial
}

nonisolated struct ContextProvenance: Codable, Sendable, Equatable {
    let sourceID: String
    let kind: ContextSourceKind
    let timestamp: Date?
    let tainted: Bool
    let sensitivity: ContextSensitivity
}

nonisolated enum ContextValidationError: Error, Sendable, Equatable {
    case emptyContent
    case credentialMaterialRejected
}

nonisolated struct ContextItem: Sendable, Equatable, Identifiable {
    let id: String
    let content: String
    let provenance: ContextProvenance
    let mandatory: Bool
    let sourceScore: Double

    static func validated(
        content: String,
        provenance: ContextProvenance,
        mandatory: Bool,
        sourceScore: Double = 0
    ) throws -> ContextItem {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ContextValidationError.emptyContent
        }
        guard provenance.sensitivity != .credentialMaterial else {
            throw ContextValidationError.credentialMaterialRejected
        }

        return ContextItem(
            id: "\(provenance.sourceID):\(stableDigest(trimmed))",
            content: trimmed,
            provenance: provenance,
            mandatory: mandatory,
            sourceScore: min(1, max(0, sourceScore))
        )
    }

    private static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

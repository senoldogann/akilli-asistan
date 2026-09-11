import Foundation

enum MemoryCandidateSource: Sendable, Equatable {
    case explicitUserFact
    case explicitPin
    case verifiedTaskFact
    case assistantOutput
    case transientToolOutput
}

struct MemoryCandidatePolicy: Sendable {
    func candidate(
        source: MemoryCandidateSource,
        content: String,
        provenance: MemoryProvenance,
        scope: MemoryScope = .user,
        confidence: Double = 1,
        tainted: Bool = false,
        sourceEvidenceID: String? = nil,
        sensitivity: ContextSensitivity = .normal,
        structuredMetadata: [String: String] = [:]
    ) -> MemoryCandidate? {
        guard sensitivity != .credentialMaterial else {
            return nil
        }
        guard !containsSensitiveMetadata(structuredMetadata) else {
            return nil
        }

        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            return nil
        }

        let normalizedEvidenceID = sourceEvidenceID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let evidenceID = normalizedEvidenceID?.isEmpty == false ? normalizedEvidenceID : nil

        switch source {
        case .explicitUserFact, .explicitPin:
            guard provenance == .user else {
                return nil
            }
        case .verifiedTaskFact:
            guard provenance == .runtimeEvidence, evidenceID != nil else {
                return nil
            }
        case .assistantOutput, .transientToolOutput:
            return nil
        }

        return MemoryCandidate(
            content: trimmedContent,
            scope: scope,
            provenance: provenance,
            confidence: min(1, max(0, confidence)),
            tainted: tainted,
            sourceEvidenceID: evidenceID
        )
    }

    private func containsSensitiveMetadata(_ metadata: [String: String]) -> Bool {
        metadata.keys.contains { key in
            let normalizedKey = key
                .lowercased()
                .filter(\.isLetter)
            return normalizedKey.contains("authorization")
                || normalizedKey.contains("cookie")
                || normalizedKey.contains("session")
        }
    }
}

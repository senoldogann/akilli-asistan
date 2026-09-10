import Foundation

enum TaskLifecycle: String, Codable, CaseIterable, Equatable, Sendable {
    case created
    case blocked
    case ready
    case planning
    case running
    case verifying
    case succeeded
    case failed
    case recovering
    case replanned
    case exhausted
    case paused
    case cancelled
    case waitingExternal
    case waitingApproval
}

struct VerificationEvidence: Codable, Equatable, Sendable {
    let evidenceID: String
    let summary: String
    let provenance: String
    let tainted: Bool
    let recordedAt: Date

    init(
        evidenceID: String = UUID().uuidString,
        summary: String,
        provenance: String,
        tainted: Bool = false,
        recordedAt: Date = Date()
    ) {
        self.evidenceID = evidenceID
        self.summary = summary
        self.provenance = provenance
        self.tainted = tainted
        self.recordedAt = recordedAt
    }
}

import Foundation

struct ReplayArtifact: Codable, Sendable, Equatable {
    let invocationID: InvocationID
    let toolID: ToolID
    let startedAt: Date
    let completedAt: Date
    let providerReference: String?
    let resultProvenance: String?
    let resultTainted: Bool
}

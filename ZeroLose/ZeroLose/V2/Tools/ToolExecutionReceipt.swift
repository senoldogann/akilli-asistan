import Foundation

struct ToolExecutionReceipt: Sendable, Equatable {
    let invocationID: InvocationID
    let toolID: ToolID
    let startedAt: Date
    let completedAt: Date
    let providerReference: String?
    let resultProvenance: String?
    let resultTainted: Bool

    init(
        invocationID: InvocationID,
        toolID: ToolID,
        startedAt: Date,
        completedAt: Date,
        providerReference: String?,
        resultProvenance: String? = nil,
        resultTainted: Bool = false
    ) {
        self.invocationID = invocationID
        self.toolID = toolID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.providerReference = providerReference
        self.resultProvenance = resultProvenance
        self.resultTainted = resultTainted
    }
}

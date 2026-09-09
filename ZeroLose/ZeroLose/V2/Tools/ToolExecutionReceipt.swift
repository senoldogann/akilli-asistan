import Foundation

struct ToolExecutionReceipt: Sendable, Equatable {
    let invocationID: InvocationID
    let toolID: ToolID
    let startedAt: Date
    let completedAt: Date
    let providerReference: String?
}

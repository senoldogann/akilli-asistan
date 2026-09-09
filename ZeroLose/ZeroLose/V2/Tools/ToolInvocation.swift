import Foundation

struct ToolInvocation: Sendable, Equatable {
    let invocationID: InvocationID
    let toolID: ToolID
    let registryRevision: UInt64
    let descriptorRevision: UInt64
    let schemaDigest: String
    let argumentsJSON: Data
    let logicalOperationKey: String?

    init(
        invocationID: InvocationID,
        toolID: ToolID,
        registryRevision: UInt64,
        descriptorRevision: UInt64,
        schemaDigest: String,
        argumentsJSON: Data,
        logicalOperationKey: String? = nil
    ) {
        self.invocationID = invocationID
        self.toolID = toolID
        self.registryRevision = registryRevision
        self.descriptorRevision = descriptorRevision
        self.schemaDigest = schemaDigest
        self.argumentsJSON = argumentsJSON
        self.logicalOperationKey = logicalOperationKey
    }
}

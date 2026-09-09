import Foundation

struct ToolInvocation: Sendable, Equatable {
    let invocationID: InvocationID
    let toolID: ToolID
    let registryRevision: UInt64
    let descriptorRevision: UInt64
    let schemaDigest: String
    let argumentsJSON: Data
}

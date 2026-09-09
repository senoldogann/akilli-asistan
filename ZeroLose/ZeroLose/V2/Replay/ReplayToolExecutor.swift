import Foundation

enum ReplayError: Error, Equatable {
    case unsupportedSchemaVersion(UInt32)
    case invalidToolArtifact
}

struct ReplayToolExecutor: Sendable {
    func receipt(for recordedEvent: RuntimeEvent) throws -> ToolExecutionReceipt {
        guard recordedEvent.schemaVersion == 1 else {
            throw ReplayError.unsupportedSchemaVersion(recordedEvent.schemaVersion)
        }

        switch recordedEvent.eventKind {
        case .tool:
            break
        default:
            throw ReplayError.invalidToolArtifact
        }

        let artifact: ReplayArtifact
        do {
            artifact = try JSONDecoder().decode(ReplayArtifact.self, from: recordedEvent.payload)
        } catch {
            throw ReplayError.invalidToolArtifact
        }

        return ToolExecutionReceipt(
            invocationID: artifact.invocationID,
            toolID: artifact.toolID,
            startedAt: artifact.startedAt,
            completedAt: artifact.completedAt,
            providerReference: artifact.providerReference,
            resultProvenance: artifact.resultProvenance,
            resultTainted: artifact.resultTainted
        )
    }
}

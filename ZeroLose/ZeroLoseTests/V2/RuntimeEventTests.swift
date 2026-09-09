import Foundation
import XCTest
@testable import ZeroLose

final class RuntimeEventTests: XCTestCase {
    func testSequenceIsOrderingAuthority() {
        let a = RuntimeEvent.test(sequence: 1, recordedAt: .distantFuture)
        let b = RuntimeEvent.test(sequence: 2, recordedAt: .distantPast)

        XCTAssertLessThan(a.sequence, b.sequence)
    }

    func testCredentialMaterialCannotBePersisted() {
        XCTAssertFalse(RedactionClass.credentialMaterial.isPersistable)
    }
}

private extension RuntimeEvent {
    static func test(sequence: UInt64, recordedAt: Date) -> Self {
        Self(
            eventID: RuntimeEventID(rawValue: "event-\(sequence)"),
            streamID: "stream-1",
            sequence: sequence,
            schemaVersion: 1,
            goalID: GoalID(rawValue: "goal-1"),
            taskID: TaskID(rawValue: "task-1"),
            sessionID: SessionID(rawValue: "session-1"),
            eventKind: .runtime,
            causationID: nil,
            correlationID: "correlation-1",
            taskGraphRevision: 1,
            toolRegistryRevision: 1,
            policyRevision: 1,
            payload: Data("{}".utf8),
            redactionClass: .normal,
            provenance: "test",
            tainted: false,
            recordedAt: recordedAt
        )
    }
}

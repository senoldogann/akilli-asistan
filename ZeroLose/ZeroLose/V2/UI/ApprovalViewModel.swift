import Observation

struct ApprovalPresentation: Identifiable, Sendable, Equatable {
    var id: String { invocationID.rawValue }
    let invocationID: InvocationID
    let summary: String
}

struct ApprovalProjectionSnapshot: Sendable, Equatable {
    let pending: [ApprovalPresentation]
}

@MainActor
@Observable
final class ApprovalViewModel {
    private(set) var pending: [ApprovalPresentation] = []
    private let commandSender: any ApplicationCommandSending

    init(commandSender: any ApplicationCommandSending) {
        self.commandSender = commandSender
    }

    func apply(_ snapshot: ApprovalProjectionSnapshot) {
        pending = snapshot.pending
    }

    func approve(_ invocationID: InvocationID) async throws {
        try await commandSender.send(.approveInvocation(invocationID))
    }

    func deny(_ invocationID: InvocationID) async throws {
        try await commandSender.send(.denyInvocation(invocationID))
    }
}

import Observation

struct ApprovalPresentation: Identifiable, Sendable, Equatable {
    var id: String { invocationID.rawValue }
    let invocationID: InvocationID
    let summary: String
    let tool: String?
    let provider: String?
    let risk: String?
    let effect: String?
    let destination: String?
    let credentialScope: String?
    let tainted: Bool
    let mutationStatus: String?
    let approvalReason: String?

    init(
        invocationID: InvocationID,
        summary: String,
        tool: String? = nil,
        provider: String? = nil,
        risk: String? = nil,
        effect: String? = nil,
        destination: String? = nil,
        credentialScope: String? = nil,
        tainted: Bool = false,
        mutationStatus: String? = nil,
        approvalReason: String? = nil
    ) {
        self.invocationID = invocationID
        self.summary = summary
        self.tool = tool
        self.provider = provider
        self.risk = risk
        self.effect = effect
        self.destination = destination
        self.credentialScope = credentialScope
        self.tainted = tainted
        self.mutationStatus = mutationStatus
        self.approvalReason = approvalReason
    }
}

struct ApprovalProjectionSnapshot: Sendable, Equatable {
    let pending: [ApprovalPresentation]
}

@MainActor
@Observable
final class ApprovalViewModel {
    private(set) var pending: [ApprovalPresentation] = []
    private let commandSender: any ApplicationCommandSending

    var pendingCount: Int { pending.count }
    var hasPendingApprovals: Bool { !pending.isEmpty }

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

protocol ApplicationCommandSending: Sendable {
    func send(_ command: ApplicationCommand) async throws
}

protocol RuntimeCommandControlling: Sendable {
    func submitUserGoal(_ text: String) async throws
    func sendChatMessage(_ text: String) async throws
    func pauseGoal(_ goalID: GoalID) async throws
    func resumeGoal(_ goalID: GoalID) async throws
    func cancelGoal(_ goalID: GoalID) async throws
    func pauseAgentSession(_ sessionID: AgentSessionID) async throws
    func resumeAgentSession(_ sessionID: AgentSessionID) async throws
    func cancelAgentSession(_ sessionID: AgentSessionID) async throws
    func emergencyStop() async throws
    func approveInvocation(_ invocationID: InvocationID) async throws
    func denyInvocation(_ invocationID: InvocationID) async throws
    func changeAuthorityMode(_ mode: AuthorityMode) async throws
}

extension RuntimeCommandControlling {
    func pauseAgentSession(_ sessionID: AgentSessionID) async throws {
        throw V2RuntimeCommandError.unsupportedCommand("agent-pause:\(sessionID.rawValue)")
    }

    func resumeAgentSession(_ sessionID: AgentSessionID) async throws {
        throw V2RuntimeCommandError.unsupportedCommand("agent-resume:\(sessionID.rawValue)")
    }

    func cancelAgentSession(_ sessionID: AgentSessionID) async throws {
        throw V2RuntimeCommandError.unsupportedCommand("agent-cancel:\(sessionID.rawValue)")
    }

    func emergencyStop() async throws {
        throw V2RuntimeCommandError.unsupportedCommand("agent-emergency-stop")
    }
}

protocol ToolManagementControlling: Sendable {
    func setToolEnabled(_ toolID: ToolID, enabled: Bool) async throws
    func setMCPServerEnabled(_ serverID: String, enabled: Bool) async throws
}

protocol MemoryCommandControlling: Sendable {
    func pinMemoryEntry(_ id: String) async throws
    func forgetMemoryEntry(_ id: String) async throws
}

actor ApplicationFacade {
    private let runtime: any RuntimeCommandControlling
    private let tools: any ToolManagementControlling
    private let memory: any MemoryCommandControlling

    init(
        runtime: any RuntimeCommandControlling,
        tools: any ToolManagementControlling,
        memory: any MemoryCommandControlling
    ) {
        self.runtime = runtime
        self.tools = tools
        self.memory = memory
    }

    func send(_ command: ApplicationCommand) async throws {
        switch command {
        case .submitUserGoal(let text):
            try await runtime.submitUserGoal(text)
        case .sendChatMessage(let text):
            try await runtime.sendChatMessage(text)
        case .pauseGoal(let goalID):
            try await runtime.pauseGoal(goalID)
        case .resumeGoal(let goalID):
            try await runtime.resumeGoal(goalID)
        case .cancelGoal(let goalID):
            try await runtime.cancelGoal(goalID)
        case .pauseAgentSession(let sessionID):
            try await runtime.pauseAgentSession(sessionID)
        case .resumeAgentSession(let sessionID):
            try await runtime.resumeAgentSession(sessionID)
        case .cancelAgentSession(let sessionID):
            try await runtime.cancelAgentSession(sessionID)
        case .emergencyStop:
            try await runtime.emergencyStop()
        case .approveInvocation(let invocationID):
            try await runtime.approveInvocation(invocationID)
        case .denyInvocation(let invocationID):
            try await runtime.denyInvocation(invocationID)
        case .enableTool(let toolID):
            try await tools.setToolEnabled(toolID, enabled: true)
        case .disableTool(let toolID):
            try await tools.setToolEnabled(toolID, enabled: false)
        case .enableMCPServer(let serverID):
            try await tools.setMCPServerEnabled(serverID, enabled: true)
        case .disableMCPServer(let serverID):
            try await tools.setMCPServerEnabled(serverID, enabled: false)
        case .forgetMemoryEntry(let id):
            try await memory.forgetMemoryEntry(id)
        case .pinMemoryEntry(let id):
            try await memory.pinMemoryEntry(id)
        case .changeAuthorityMode(let mode):
            try await runtime.changeAuthorityMode(mode)
        }
    }
}

extension ApplicationFacade: ApplicationCommandSending {}

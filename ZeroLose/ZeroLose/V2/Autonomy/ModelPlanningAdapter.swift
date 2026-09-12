import Foundation

struct ModelPlanningAdapter: Planning, Sendable {
    private let providerFabric: ModelProviderFabric
    private let modelID: String

    init(providerFabric: ModelProviderFabric, modelID: String) {
        self.providerFabric = providerFabric
        self.modelID = modelID
    }

    func propose(
        goal: GoalSnapshot,
        graph: TaskGraphSnapshot,
        budgets: RuntimeBudgetSnapshot,
        context: PlanningContext
    ) async throws -> PlanningProposal {
        let request = ModelRequest(
            sessionID: ModelSessionID(rawValue: "planning:\(goal.id.rawValue)"),
            conversation: [
                ModelMessage(role: .system, content: Self.systemPrompt),
                ModelMessage(
                    role: .user,
                    content: Self.userPrompt(
                        goal: goal,
                        graph: graph,
                        budgets: budgets,
                        context: context
                    )
                )
            ],
            modelID: modelID,
            tools: [],
            responseMode: .json
        )

        let stream = try await providerFabric.stream(request)
        var output = ""
        var completed = false

        for try await event in stream {
            switch event {
            case .started:
                break
            case .textDelta(let delta):
                output += delta
            case .toolCall:
                throw PlanningError.invalidProposal
            case .completed:
                completed = true
            }
        }

        guard completed,
              let data = output.data(using: .utf8),
              let modelPlan = try? JSONDecoder().decode(ModelPlan.self, from: data) else {
            throw PlanningError.invalidProposal
        }

        return try makeProposal(
            from: modelPlan,
            graph: graph,
            registry: context.registry
        )
    }

    private func makeProposal(
        from plan: ModelPlan,
        graph: TaskGraphSnapshot,
        registry: ToolRegistrySnapshot
    ) throws -> PlanningProposal {
        var seenTaskIDs = Set<TaskID>()
        var taskDefinitions: [TaskID: ModelPlanTask] = [:]

        for task in plan.tasks {
            let trimmedID = task.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty else {
                throw PlanningError.invalidProposal
            }

            let taskID = TaskID(rawValue: trimmedID)
            guard graph.tasks[taskID] == nil,
                  seenTaskIDs.insert(taskID).inserted else {
                throw PlanningError.invalidProposal
            }
            taskDefinitions[taskID] = task
        }

        let existingTaskIDs = Set(graph.tasks.keys)
        let newTaskIDs = Set(taskDefinitions.keys)
        let allowedDependencyIDs = existingTaskIDs.union(newTaskIDs)
        var dependencies: [TaskDependency] = []
        var nodes: [TaskNode] = []
        nodes.reserveCapacity(plan.tasks.count)

        for task in plan.tasks {
            let taskID = TaskID(
                rawValue: task.id.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let dependencyIDs = task.dependencies.map {
                TaskID(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            guard dependencyIDs.allSatisfy({ !$0.rawValue.isEmpty }),
                  Set(dependencyIDs).count == dependencyIDs.count,
                  dependencyIDs.allSatisfy({ $0 != taskID && allowedDependencyIDs.contains($0) }) else {
                throw PlanningError.invalidProposal
            }

            let toolID = ToolID(rawValue: task.toolID.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !toolID.rawValue.isEmpty,
                  let descriptor = registry.descriptors[toolID],
                  descriptor.enabled else {
                throw PlanningError.invalidProposal
            }

            let argumentsJSON: Data
            do {
                argumentsJSON = try JSONEncoder().encode(task.arguments)
            } catch {
                throw PlanningError.invalidProposal
            }

            let concurrencyClass: ConcurrencyClass = descriptor.concurrencyClass == .read
                ? .read
                : .mutation
            nodes.append(
                TaskNode(
                    id: taskID,
                    title: taskID.rawValue,
                    dependencies: Set(dependencyIDs),
                    concurrencyClass: concurrencyClass,
                    plannedInvocation: PlannedToolInvocation(
                        toolID: toolID,
                        argumentsJSON: argumentsJSON
                    )
                )
            )
            dependencies.append(
                contentsOf: dependencyIDs.map {
                    TaskDependency(taskID: taskID, dependsOn: $0)
                }
            )
        }

        try Self.validateAcyclicDependencies(
            definitions: taskDefinitions,
            newTaskIDs: newTaskIDs
        )

        return PlanningProposal(
            addTasks: nodes,
            addDependencies: dependencies,
            markBlocked: []
        )
    }

    private static func validateAcyclicDependencies(
        definitions: [TaskID: ModelPlanTask],
        newTaskIDs: Set<TaskID>
    ) throws {
        enum VisitState {
            case visiting
            case visited
        }

        var states: [TaskID: VisitState] = [:]

        func visit(_ taskID: TaskID) throws {
            if let state = states[taskID] {
                if state == .visiting {
                    throw PlanningError.invalidProposal
                }
                return
            }

            states[taskID] = .visiting
            if let definition = definitions[taskID] {
                for rawDependency in definition.dependencies {
                    let dependencyID = TaskID(
                        rawValue: rawDependency.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    if newTaskIDs.contains(dependencyID) {
                        try visit(dependencyID)
                    }
                }
            }
            states[taskID] = .visited
        }

        for taskID in newTaskIDs {
            try visit(taskID)
        }
    }

    private static let systemPrompt = """
    Return one JSON object only. The schema is:
    {"tasks":[{"id":"string","dependencies":["task-id"],"toolID":"enabled-tool-id","arguments":{}}]}
    Use only enabled tool IDs provided by the user message. Do not execute tools and do not include prose.
    """

    private static func userPrompt(
        goal: GoalSnapshot,
        graph: TaskGraphSnapshot,
        budgets: RuntimeBudgetSnapshot,
        context: PlanningContext
    ) -> String {
        let tools = context.registry.descriptors.values
            .filter(\.enabled)
            .sorted { $0.id.rawValue < $1.id.rawValue }
            .map { descriptor in
                let schema = String(data: descriptor.inputSchemaJSON, encoding: .utf8) ?? "{}"
                return "- \(descriptor.id.rawValue): \(schema)"
            }
            .joined(separator: "\n")
        let retrievedContext = context.retrievedContext.items
            .map { "[\($0.provenance.kind.rawValue)] \($0.content)" }
            .joined(separator: "\n")
        let existingTasks = graph.tasks.keys
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")

        return """
        Goal: \(goal.objective)
        Existing task IDs: \(existingTasks)
        Remaining model calls: \(budgets.remainingModelCalls)
        Remaining tool calls: \(budgets.remainingToolCalls)
        Remaining recovery attempts: \(budgets.remainingRecoveryAttempts)
        Enabled tools:
        \(tools)
        Relevant context:
        \(retrievedContext)
        """
    }
}

private struct ModelPlan: Decodable {
    let tasks: [ModelPlanTask]
}

private struct ModelPlanTask: Decodable {
    let id: String
    let dependencies: [String]
    let toolID: String
    let arguments: PlanningJSONValue
}

private enum PlanningJSONValue: Codable, Sendable, Equatable {
    case object([String: PlanningJSONValue])
    case array([PlanningJSONValue])
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let object = try? container.decode([String: PlanningJSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([PlanningJSONValue].self) {
            self = .array(array)
        } else if let boolean = try? container.decode(Bool.self) {
            self = .boolean(boolean)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported planning JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let object):
            try container.encode(object)
        case .array(let array):
            try container.encode(array)
        case .string(let string):
            try container.encode(string)
        case .number(let number):
            try container.encode(number)
        case .boolean(let boolean):
            try container.encode(boolean)
        case .null:
            try container.encodeNil()
        }
    }
}

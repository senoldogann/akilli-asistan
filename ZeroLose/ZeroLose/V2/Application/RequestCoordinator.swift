import Foundation

actor RequestCoordinator {
    private let contextOrchestrator: ContextOrchestrator
    private let providerFabric: ModelProviderFabric
    private let conversationStore: any ConversationStoring
    private let readOnlyToolSchemas: [ModelToolSchema]

    init(
        contextOrchestrator: ContextOrchestrator,
        providerFabric: ModelProviderFabric,
        conversationStore: any ConversationStoring,
        readOnlyToolSchemas: [ModelToolSchema] = []
    ) {
        self.contextOrchestrator = contextOrchestrator
        self.providerFabric = providerFabric
        self.conversationStore = conversationStore
        self.readOnlyToolSchemas = readOnlyToolSchemas
    }

    func stream(_ request: AskRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.execute(request, continuation: continuation)
            }
        }
    }

    func cancel(sessionID: ModelSessionID) async {
        await providerFabric.cancel(sessionID: sessionID)
    }

    private func execute(
        _ request: AskRequest,
        continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation
    ) async {
        do {
            let trimmedText = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else {
                throw RequestCoordinatorError.emptyUserText
            }

            let previousMessages = try await conversationStore.messages(
                conversationID: request.conversationID
            )

            let context = try await contextOrchestrator.buildContext(
                for: ContextQuery(
                    text: request.text,
                    conversationID: request.conversationID,
                    activeGoalID: request.activeGoalID
                )
            )

            let userMessage = ConversationMessage(
                id: UUID().uuidString,
                conversationID: request.conversationID,
                role: .user,
                text: request.text,
                recordedAt: Date(),
                provenance: ConversationProvenance(source: .native),
                verifiedSemanticTruth: false
            )
            try await conversationStore.save(userMessage)

            var conversation: [ModelMessage] = []
            if let systemMessage = systemMessage(from: context) {
                conversation.append(systemMessage)
            }
            conversation.append(contentsOf: previousMessages.compactMap(modelMessage(from:)))
            conversation.append(ModelMessage(role: .user, content: request.text))

            let modelRequest = ModelRequest(
                sessionID: request.sessionID,
                conversation: conversation,
                modelID: request.modelID,
                tools: filteredReadOnlyToolSchemas(),
                responseMode: .text
            )

            let providerStream = try await providerFabric.stream(modelRequest)
            var assistantText = ""
            var completed = false

            for try await event in providerStream {
                switch event {
                case .textDelta(let delta):
                    assistantText += delta
                case .completed:
                    completed = true
                case .started, .toolCall:
                    break
                }
                continuation.yield(event)
            }

            if completed && !assistantText.isEmpty {
                let assistantMessage = ConversationMessage(
                    id: UUID().uuidString,
                    conversationID: request.conversationID,
                    role: .assistant,
                    text: assistantText,
                    recordedAt: Date(),
                    provenance: ConversationProvenance(source: .native),
                    verifiedSemanticTruth: false
                )
                try await conversationStore.save(assistantMessage)
            }

            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func systemMessage(from context: ContextBundle) -> ModelMessage? {
        guard !context.items.isEmpty else {
            return nil
        }

        let content = context.items
            .map { item in
                "[\(item.provenance.kind.rawValue)] \(item.content)"
            }
            .joined(separator: "\n")

        return ModelMessage(role: .system, content: content)
    }

    private func modelMessage(from message: ConversationMessage) -> ModelMessage? {
        switch message.role {
        case .user:
            return ModelMessage(role: .user, content: message.text)
        case .assistant:
            return ModelMessage(role: .assistant, content: message.text)
        case .transcript:
            return nil
        }
    }

    private func filteredReadOnlyToolSchemas() -> [ModelToolSchema] {
        readOnlyToolSchemas.filter { schema in
            let name = schema.name.lowercased()
            return !name.hasPrefix("computer.")
                && !name.hasPrefix("browser.mutate")
                && !name.hasPrefix("shell.")
                && !name.hasPrefix("physical.")
        }
    }
}

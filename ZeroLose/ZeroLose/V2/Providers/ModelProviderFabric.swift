import Foundation

actor ModelProviderFabric {
    private let providers: [ModelProviderID: any ModelProvider]
    private var selectedProviderID: ModelProviderID

    init(
        providers: [any ModelProvider],
        selectedProviderID: ModelProviderID
    ) {
        self.providers = Dictionary(
            uniqueKeysWithValues: providers.map { ($0.id, $0) }
        )
        self.selectedProviderID = selectedProviderID
    }

    func select(_ providerID: ModelProviderID) {
        selectedProviderID = providerID
    }

    func stream(
        _ request: ModelRequest
    ) throws -> AsyncThrowingStream<ModelEvent, Error> {
        guard let provider = providers[selectedProviderID] else {
            throw ProviderError.providerUnavailable(providerID: selectedProviderID)
        }
        return provider.stream(request)
    }

    func selectedModelSupports(
        _ capability: ModelCapabilities,
        modelID: String
    ) async -> Bool {
        guard let provider = providers[selectedProviderID],
              provider.capabilities.contains(capability),
              let models = try? await provider.discoverModels(),
              !models.isEmpty else {
            return false
        }

        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedModelID.isEmpty || normalizedModelID == "default" {
            guard models.count == 1, let model = models.first else {
                return false
            }
            return model.providerID == provider.id
                && model.capabilities.contains(capability)
        }

        guard let model = models.first(where: {
            $0.id == normalizedModelID && $0.providerID == provider.id
        }) else {
            return false
        }
        return model.capabilities.contains(capability)
    }

    func selectedStatus() async -> ProviderStatus {
        guard let provider = providers[selectedProviderID] else {
            return ProviderStatus(
                providerID: selectedProviderID,
                displayName: selectedProviderID.rawValue,
                availability: .unavailable
            )
        }
        return await provider.status()
    }

    func statuses() async -> [ProviderStatus] {
        var result: [ProviderStatus] = []
        result.reserveCapacity(providers.count)

        for provider in providers.values {
            result.append(await provider.status())
        }

        return result.sorted {
            $0.providerID.rawValue < $1.providerID.rawValue
        }
    }

    func discoverModels(
        for providerID: ModelProviderID
    ) async throws -> [ModelDescriptor] {
        guard let provider = providers[providerID] else {
            throw ProviderError.providerUnavailable(providerID: providerID)
        }
        return try await provider.discoverModels()
    }

    func cancel(sessionID: ModelSessionID) async {
        guard let provider = providers[selectedProviderID] else {
            return
        }
        await provider.cancel(sessionID: sessionID)
    }
}

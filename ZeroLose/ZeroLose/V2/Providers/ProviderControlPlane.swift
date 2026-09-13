import Foundation

nonisolated struct ProviderSelectionSnapshot: Sendable, Equatable {
    let providerID: ModelProviderID
    let modelID: String
    let revision: UInt64
}

nonisolated enum ModelDiscoveryState: Sendable, Equatable {
    case idle
    case loaded
    case failed
}

nonisolated struct ProviderPresentation: Identifiable, Sendable, Equatable {
    let id: ModelProviderID
    let displayName: String
    let availability: ProviderAvailability
    let capabilities: ModelCapabilities
    let models: [ModelDescriptor]
    let modelDiscoveryState: ModelDiscoveryState
}

nonisolated struct ProviderControlSnapshot: Sendable, Equatable {
    let providers: [ProviderPresentation]
    let selection: ProviderSelectionSnapshot
}

nonisolated enum ProviderControlPlaneError: Error, Sendable, Equatable {
    case noRegisteredProviders
    case unknownProvider(ModelProviderID)
    case invalidModel(providerID: ModelProviderID, modelID: String)
}

nonisolated protocol ProviderSelectionPersisting: Sendable {
    func loadProviderID() async -> String?
    func loadModelID() async -> String?
    func save(providerID: String, modelID: String) async
}

actor UserDefaultsProviderSelectionStore: ProviderSelectionPersisting {
    static let providerKey = "v2.modelProviderID"
    static let modelKey = "v2.modelDefaultID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadProviderID() async -> String? {
        defaults.string(forKey: Self.providerKey)
    }

    func loadModelID() async -> String? {
        defaults.string(forKey: Self.modelKey)
    }

    func save(providerID: String, modelID: String) async {
        defaults.set(providerID, forKey: Self.providerKey)
        defaults.set(modelID, forKey: Self.modelKey)
    }
}

actor ProviderControlPlane {
    private let fabric: ModelProviderFabric
    private let persistence: any ProviderSelectionPersisting

    private var cachedSnapshot: ProviderControlSnapshot?
    private var revision: UInt64 = 0

    init(
        fabric: ModelProviderFabric,
        persistence: any ProviderSelectionPersisting = UserDefaultsProviderSelectionStore()
    ) {
        self.fabric = fabric
        self.persistence = persistence
    }

    func snapshot() async -> ProviderControlSnapshot {
        if let cachedSnapshot {
            return cachedSnapshot
        }
        return await bootstrap()
    }

    func refresh() async -> ProviderControlSnapshot {
        let current = await ensureSelection()
        let providers = await presentations()
        var selection = current

        if selection.modelID != "default",
           !Self.modelIsValid(selection.modelID, providerID: selection.providerID, providers: providers) {
            revision &+= 1
            selection = ProviderSelectionSnapshot(
                providerID: selection.providerID,
                modelID: "default",
                revision: revision
            )
            await persistence.save(
                providerID: selection.providerID.rawValue,
                modelID: selection.modelID
            )
        }

        let updated = ProviderControlSnapshot(providers: providers, selection: selection)
        cachedSnapshot = updated
        return updated
    }

    func currentSelection() async -> ProviderSelectionSnapshot {
        await ensureSelection()
    }

    func selectProvider(
        _ providerID: ModelProviderID
    ) async throws -> ProviderControlSnapshot {
        let current = await ensureSelection()
        let registered = await fabric.registeredProviderIDs()
        guard registered.contains(providerID) else {
            throw ProviderControlPlaneError.unknownProvider(providerID)
        }

        guard providerID != current.providerID else {
            return await snapshot()
        }

        revision &+= 1
        let selection = ProviderSelectionSnapshot(
            providerID: providerID,
            modelID: "default",
            revision: revision
        )
        await fabric.select(providerID)
        await persistence.save(providerID: providerID.rawValue, modelID: "default")

        let updated = ProviderControlSnapshot(
            providers: await presentations(),
            selection: selection
        )
        cachedSnapshot = updated
        return updated
    }

    func selectModel(_ modelID: String) async throws -> ProviderControlSnapshot {
        let current = await ensureSelection()
        let normalized = Self.normalizedModelID(modelID)
        let currentSnapshot = await snapshot()

        guard normalized == "default"
                || Self.modelIsValid(
                    normalized,
                    providerID: current.providerID,
                    providers: currentSnapshot.providers
                ) else {
            throw ProviderControlPlaneError.invalidModel(
                providerID: current.providerID,
                modelID: normalized
            )
        }

        guard normalized != current.modelID else {
            return currentSnapshot
        }

        revision &+= 1
        let selection = ProviderSelectionSnapshot(
            providerID: current.providerID,
            modelID: normalized,
            revision: revision
        )
        await persistence.save(
            providerID: current.providerID.rawValue,
            modelID: normalized
        )
        let updated = ProviderControlSnapshot(
            providers: currentSnapshot.providers,
            selection: selection
        )
        cachedSnapshot = updated
        return updated
    }

    func canUseChat() async -> Bool {
        let state = await snapshot()
        guard let provider = state.providers.first(where: {
            $0.id == state.selection.providerID
        }),
        Self.isOperational(provider.availability),
        provider.capabilities.contains(.textStreaming) else {
            return false
        }

        return state.selection.modelID == "default"
            || Self.modelIsValid(
                state.selection.modelID,
                providerID: state.selection.providerID,
                providers: state.providers
            )
    }

    func canUseAgent() async -> Bool {
        let state = await snapshot()
        guard let provider = state.providers.first(where: {
            $0.id == state.selection.providerID
        }),
        Self.isOperational(provider.availability),
        provider.capabilities.contains(.jsonOutput) else {
            return false
        }

        if state.selection.modelID == "default" {
            guard provider.models.count == 1,
                  let defaultTarget = provider.models.first else {
                return false
            }
            return defaultTarget.capabilities.contains(.jsonOutput)
        }

        guard let model = provider.models.first(where: {
            $0.id == state.selection.modelID && $0.providerID == provider.id
        }) else {
            return false
        }
        return model.capabilities.contains(.jsonOutput)
    }

    private func bootstrap() async -> ProviderControlSnapshot {
        let registered = await fabric.registeredProviderIDs()
        let storedProvider = await persistence.loadProviderID()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let storedModel = await persistence.loadModelID()?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let selectedProviderID = Self.resolveProviderID(
            storedProvider,
            registered: registered
        )
        await fabric.select(selectedProviderID)

        let providers = await presentations(registeredProviderIDs: registered)
        let candidateModel = Self.normalizedModelID(storedModel ?? "default")
        let selectedModelID: String
        if candidateModel == "default"
            || Self.modelIsValid(
                candidateModel,
                providerID: selectedProviderID,
                providers: providers
            ) {
            selectedModelID = candidateModel
        } else {
            selectedModelID = "default"
        }

        let selection = ProviderSelectionSnapshot(
            providerID: selectedProviderID,
            modelID: selectedModelID,
            revision: revision
        )
        let result = ProviderControlSnapshot(
            providers: providers,
            selection: selection
        )
        cachedSnapshot = result

        if storedProvider != selectedProviderID.rawValue || storedModel != selectedModelID {
            await persistence.save(
                providerID: selectedProviderID.rawValue,
                modelID: selectedModelID
            )
        }
        return result
    }

    private func ensureSelection() async -> ProviderSelectionSnapshot {
        if let cachedSnapshot {
            return cachedSnapshot.selection
        }
        return await bootstrap().selection
    }

    private func presentations(
        registeredProviderIDs: [ModelProviderID]? = nil
    ) async -> [ProviderPresentation] {
        let registered: [ModelProviderID]
        if let registeredProviderIDs {
            registered = registeredProviderIDs
        } else {
            registered = await fabric.registeredProviderIDs()
        }
        var result: [ProviderPresentation] = []
        result.reserveCapacity(registered.count)

        for providerID in registered {
            let status = await fabric.status(for: providerID)
            let capabilities = (try? await fabric.capabilities(for: providerID)) ?? []
            do {
                let models = try await fabric.discoverModels(for: providerID)
                    .filter { $0.providerID == providerID }
                    .sorted { $0.id < $1.id }
                result.append(
                    ProviderPresentation(
                        id: providerID,
                        displayName: status.displayName,
                        availability: status.availability,
                        capabilities: capabilities,
                        models: models,
                        modelDiscoveryState: .loaded
                    )
                )
            } catch {
                result.append(
                    ProviderPresentation(
                        id: providerID,
                        displayName: status.displayName,
                        availability: status.availability,
                        capabilities: capabilities,
                        models: [],
                        modelDiscoveryState: .failed
                    )
                )
            }
        }

        return result.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private static func resolveProviderID(
        _ storedProviderID: String?,
        registered: [ModelProviderID]
    ) -> ModelProviderID {
        if let storedProviderID,
           let exact = registered.first(where: { $0.rawValue == storedProviderID }) {
            return exact
        }

        let codex = ModelProviderID(rawValue: "codex")
        if registered.contains(codex) {
            return codex
        }
        return registered.first ?? ModelProviderID(rawValue: "unavailable")
    }

    private static func normalizedModelID(_ modelID: String) -> String {
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "default" : normalized
    }

    private static func modelIsValid(
        _ modelID: String,
        providerID: ModelProviderID,
        providers: [ProviderPresentation]
    ) -> Bool {
        guard let provider = providers.first(where: { $0.id == providerID }) else {
            return false
        }
        return provider.models.contains {
            $0.id == modelID && $0.providerID == providerID
        }
    }

    private static func isOperational(_ availability: ProviderAvailability) -> Bool {
        availability == .ready || availability == .detected
    }
}

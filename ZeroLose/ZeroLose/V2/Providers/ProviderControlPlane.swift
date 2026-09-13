import Foundation

nonisolated struct ProviderSelectionSnapshot: Sendable, Equatable {
    let providerID: ModelProviderID
    let modelID: String
    /// Reasoning effort bound to the selection, or `nil` to use the model's own
    /// default (or no effort control at all).
    let reasoningEffort: String?
    let revision: UInt64

    nonisolated init(
        providerID: ModelProviderID,
        modelID: String,
        reasoningEffort: String? = nil,
        revision: UInt64
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.revision = revision
    }
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
    case invalidReasoningEffort(providerID: ModelProviderID, modelID: String, effort: String)
}

nonisolated protocol ProviderSelectionPersisting: Sendable {
    func loadProviderID() async -> String?
    func loadModelID() async -> String?
    func loadReasoningEffort() async -> String?
    func save(providerID: String, modelID: String) async
    func saveReasoningEffort(_ effort: String?) async
}

actor UserDefaultsProviderSelectionStore: ProviderSelectionPersisting {
    static let providerKey = "v2.modelProviderID"
    static let modelKey = "v2.modelDefaultID"
    static let reasoningEffortKey = "v2.modelReasoningEffort"

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

    func loadReasoningEffort() async -> String? {
        defaults.string(forKey: Self.reasoningEffortKey)
    }

    func save(providerID: String, modelID: String) async {
        defaults.set(providerID, forKey: Self.providerKey)
        defaults.set(modelID, forKey: Self.modelKey)
    }

    func saveReasoningEffort(_ effort: String?) async {
        guard let effort, !effort.isEmpty else {
            defaults.removeObject(forKey: Self.reasoningEffortKey)
            return
        }
        defaults.set(effort, forKey: Self.reasoningEffortKey)
    }
}

actor ProviderControlPlane {
    private let fabric: ModelProviderFabric
    private let persistence: any ProviderSelectionPersisting

    private var cachedSnapshot: ProviderControlSnapshot?
    private var revision: UInt64 = 0
    private var mutationTail: Task<Void, Never> = Task {}

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
        return await runExclusively {
            if let cached = await self.cachedSnapshotIfPresent() {
                return cached
            }
            return await self.bootstrap()
        }
    }

    func refresh() async -> ProviderControlSnapshot {
        await runExclusively { await self.performRefresh() }
    }

    func currentSelection() async -> ProviderSelectionSnapshot {
        if let cachedSnapshot {
            return cachedSnapshot.selection
        }
        return await runExclusively {
            if let cached = await self.cachedSnapshotIfPresent() {
                return cached.selection
            }
            return await self.bootstrap().selection
        }
    }

    func selectProvider(
        _ providerID: ModelProviderID
    ) async throws -> ProviderControlSnapshot {
        try await runExclusivelyThrowing {
            try await self.performSelectProvider(providerID)
        }
    }

    func selectModel(_ modelID: String) async throws -> ProviderControlSnapshot {
        try await runExclusivelyThrowing {
            try await self.performSelectModel(modelID)
        }
    }

    /// Binds a reasoning effort to the current selection. `nil` (or an empty
    /// string) clears it so the model's own default applies. An effort the
    /// selected model does not publish is rejected rather than forwarded to a CLI
    /// that would silently ignore or fail on it.
    func selectReasoningEffort(_ effort: String?) async throws -> ProviderControlSnapshot {
        try await runExclusivelyThrowing {
            try await self.performSelectReasoningEffort(effort)
        }
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

    /// Serializes control-plane mutations so a slower earlier call cannot overwrite the
    /// result of a call made after it: each operation waits for the previously enqueued
    /// one to finish before it runs, so fabric selection, persistence, and
    /// `cachedSnapshot` all update in call order rather than completion order. Only call
    /// this from a public entry point — `performRefresh`/`performSelectProvider`/
    /// `performSelectModel`/`bootstrap` must not call back into it, or a turn would wait
    /// on itself.
    private func runExclusively<T: Sendable>(
        _ operation: @escaping @Sendable () async -> T
    ) async -> T {
        let previous = mutationTail
        let task = Task<T, Never> {
            _ = await previous.value
            return await operation()
        }
        mutationTail = Task { _ = await task.value }
        return await task.value
    }

    private func runExclusivelyThrowing<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = mutationTail
        let task = Task<Result<T, Error>, Never> {
            _ = await previous.value
            do {
                return .success(try await operation())
            } catch {
                return .failure(error)
            }
        }
        mutationTail = Task { _ = await task.value }
        return try await task.value.get()
    }

    private func cachedSnapshotIfPresent() -> ProviderControlSnapshot? {
        cachedSnapshot
    }

    private func performRefresh() async -> ProviderControlSnapshot {
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
            await persistence.saveReasoningEffort(nil)
        } else if let effort = selection.reasoningEffort,
                  !Self.effortIsValid(
                      effort,
                      selection: selection,
                      providers: providers
                  ) {
            // A model whose published reasoning levels changed must not keep a
            // stale effort that would be forwarded to the CLI unchecked.
            revision &+= 1
            selection = ProviderSelectionSnapshot(
                providerID: selection.providerID,
                modelID: selection.modelID,
                revision: revision
            )
            await persistence.saveReasoningEffort(nil)
        }

        let updated = ProviderControlSnapshot(providers: providers, selection: selection)
        cachedSnapshot = updated
        return updated
    }

    private func performSelectProvider(
        _ providerID: ModelProviderID
    ) async throws -> ProviderControlSnapshot {
        let current = await ensureSelection()
        let registered = await fabric.registeredProviderIDs()
        guard registered.contains(providerID) else {
            throw ProviderControlPlaneError.unknownProvider(providerID)
        }

        guard providerID != current.providerID else {
            if let cachedSnapshot {
                return cachedSnapshot
            }
            return await bootstrap()
        }

        revision &+= 1
        let selection = ProviderSelectionSnapshot(
            providerID: providerID,
            modelID: "default",
            revision: revision
        )
        await fabric.select(providerID)
        await persistence.save(providerID: providerID.rawValue, modelID: "default")
        // Reasoning levels belong to a provider's models, so switching provider
        // clears the previous provider's effort.
        await persistence.saveReasoningEffort(nil)

        let updated = ProviderControlSnapshot(
            providers: await presentations(),
            selection: selection
        )
        cachedSnapshot = updated
        return updated
    }

    private func performSelectReasoningEffort(
        _ effort: String?
    ) async throws -> ProviderControlSnapshot {
        let currentSnapshot: ProviderControlSnapshot
        if let cachedSnapshot {
            currentSnapshot = cachedSnapshot
        } else {
            currentSnapshot = await bootstrap()
        }
        let current = currentSnapshot.selection
        let normalized = Self.normalizedEffort(effort)

        if let normalized {
            guard let model = Self.selectedModel(in: currentSnapshot),
                  model.supportsReasoningEffort(normalized) else {
                throw ProviderControlPlaneError.invalidReasoningEffort(
                    providerID: current.providerID,
                    modelID: current.modelID,
                    effort: normalized
                )
            }
        }

        guard normalized != current.reasoningEffort else {
            return currentSnapshot
        }

        revision &+= 1
        let selection = ProviderSelectionSnapshot(
            providerID: current.providerID,
            modelID: current.modelID,
            reasoningEffort: normalized,
            revision: revision
        )
        await persistence.saveReasoningEffort(normalized)
        let updated = ProviderControlSnapshot(
            providers: currentSnapshot.providers,
            selection: selection
        )
        cachedSnapshot = updated
        return updated
    }

    private func performSelectModel(_ modelID: String) async throws -> ProviderControlSnapshot {
        let current = await ensureSelection()
        let normalized = Self.normalizedModelID(modelID)
        let currentSnapshot: ProviderControlSnapshot
        if let cachedSnapshot {
            currentSnapshot = cachedSnapshot
        } else {
            currentSnapshot = await bootstrap()
        }

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
        // A different model has different reasoning levels, so any bound effort is
        // cleared rather than silently carried onto a model that may not accept it.
        let selection = ProviderSelectionSnapshot(
            providerID: current.providerID,
            modelID: normalized,
            revision: revision
        )
        await persistence.save(
            providerID: current.providerID.rawValue,
            modelID: normalized
        )
        await persistence.saveReasoningEffort(nil)
        let updated = ProviderControlSnapshot(
            providers: currentSnapshot.providers,
            selection: selection
        )
        cachedSnapshot = updated
        return updated
    }

    private func bootstrap() async -> ProviderControlSnapshot {
        let registered = await fabric.registeredProviderIDs()
        let storedProvider = await persistence.loadProviderID()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let storedModel = await persistence.loadModelID()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let storedEffort = await persistence.loadReasoningEffort()

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

        let candidateSelection = ProviderSelectionSnapshot(
            providerID: selectedProviderID,
            modelID: selectedModelID,
            reasoningEffort: Self.normalizedEffort(storedEffort),
            revision: revision
        )
        let selectedEffort = candidateSelection.reasoningEffort.flatMap { effort in
            Self.effortIsValid(
                effort,
                selection: candidateSelection,
                providers: providers
            ) ? effort : nil
        }

        let selection = ProviderSelectionSnapshot(
            providerID: selectedProviderID,
            modelID: selectedModelID,
            reasoningEffort: selectedEffort,
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
        if selectedEffort != Self.normalizedEffort(storedEffort) {
            await persistence.saveReasoningEffort(selectedEffort)
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

    /// `nil` and “” both mean “no explicit effort”.
    private static func normalizedEffort(_ effort: String?) -> String? {
        let normalized = effort?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }

    /// Reasoning options are a property of the explicitly selected model: while the
    /// selection is "default" this build does not know which model the CLI will
    /// run, so no effort is offered or accepted.
    private static func selectedModel(in snapshot: ProviderControlSnapshot) -> ModelDescriptor? {
        let selection = snapshot.selection
        guard selection.modelID != "default" else { return nil }
        return snapshot.providers
            .first { $0.id == selection.providerID }?
            .models
            .first { $0.id == selection.modelID && $0.providerID == selection.providerID }
    }

    private static func effortIsValid(
        _ effort: String,
        selection: ProviderSelectionSnapshot,
        providers: [ProviderPresentation]
    ) -> Bool {
        guard let model = providers
            .first(where: { $0.id == selection.providerID })?
            .models
            .first(where: {
                $0.id == selection.modelID && $0.providerID == selection.providerID
            }) else {
            return false
        }
        return model.supportsReasoningEffort(effort)
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

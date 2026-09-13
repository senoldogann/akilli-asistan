import Foundation

/// Parses the model catalog that the Codex CLI itself publishes through
/// `codex debug models` ("Render the raw model catalog as JSON").
///
/// The catalog is the authority for which models this Codex build can run, along
/// with each model's reasoning levels and input modalities. Nothing here is
/// hardcoded: an unknown or unreadable catalog yields no models instead of
/// inventing entries.
nonisolated enum CodexModelCatalog {
    static let arguments = ["debug", "models"]
    static let timeoutSeconds: TimeInterval = 60

    static func models(
        from data: Data,
        providerID: ModelProviderID
    ) -> [ModelDescriptor] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = root["models"] as? [[String: Any]]
        else {
            return []
        }

        return entries.compactMap { entry in
            descriptor(from: entry, providerID: providerID)
        }
    }

    private static func descriptor(
        from entry: [String: Any],
        providerID: ModelProviderID
    ) -> ModelDescriptor? {
        guard
            let slug = entry["slug"] as? String,
            !slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        // `visibility` gates picker entry: hidden/internal catalog rows exist and
        // must not be offered as choices.
        if let visibility = entry["visibility"] as? String,
           visibility != "list" {
            return nil
        }

        let displayName = (entry["display_name"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let efforts = reasoningEfforts(from: entry)
        let defaultEffort = (entry["default_reasoning_level"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ModelDescriptor(
            id: slug,
            displayName: displayName.flatMap { $0.isEmpty ? nil : $0 } ?? slug,
            providerID: providerID,
            capabilities: capabilities(from: entry),
            reasoningEfforts: efforts,
            defaultReasoningEffort: defaultEffort.flatMap {
                efforts.contains($0) ? $0 : nil
            }
        )
    }

    private static func capabilities(from entry: [String: Any]) -> ModelCapabilities {
        var capabilities: ModelCapabilities = [.textStreaming, .reasoningControl]
        if let modalities = entry["input_modalities"] as? [String],
           modalities.contains(where: { $0.lowercased() == "image" }) {
            capabilities.insert(.vision)
        }
        return capabilities
    }

    private static func reasoningEfforts(from entry: [String: Any]) -> [String] {
        guard let levels = entry["supported_reasoning_levels"] as? [[String: Any]] else {
            return []
        }
        return levels.compactMap { level in
            guard let effort = level["effort"] as? String else { return nil }
            let trimmed = effort.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

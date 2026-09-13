import Foundation

/// Parses the `opencode models` listing (one `provider/model` identifier per line).
///
/// The listing is line-oriented and may carry extra decoration before the first
/// identifier, so only lines that look like a `provider/model` id are accepted.
nonisolated enum OpenCodeModelCatalog {
    static func models(
        from listing: String,
        providerID: ModelProviderID
    ) -> [ModelDescriptor] {
        listing
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                descriptor(from: String(line), providerID: providerID)
            }
    }

    private static func descriptor(
        from rawLine: String,
        providerID: ModelProviderID
    ) -> ModelDescriptor? {
        let identifier = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty,
              identifier.contains("/"),
              !identifier.contains(" "),
              !identifier.hasPrefix("{"),
              !identifier.hasPrefix("\"") else {
            return nil
        }

        return ModelDescriptor(
            id: identifier,
            displayName: displayName(for: identifier),
            providerID: providerID,
            capabilities: [.textStreaming, .reasoningControl]
        )
    }

    /// `opencode-go/deepseek-v4-pro` → `deepseek-v4-pro (opencode-go)`, so models
    /// with the same name from different providers stay distinguishable.
    private static func displayName(for identifier: String) -> String {
        let parts = identifier.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return identifier }
        return "\(parts[1]) (\(parts[0]))"
    }
}

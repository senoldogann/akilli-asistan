struct PluginManifest: Codable, Sendable, Equatable {
    let id: String
    let version: String
    let capabilities: [String]
    let credentialScopes: [String]
}

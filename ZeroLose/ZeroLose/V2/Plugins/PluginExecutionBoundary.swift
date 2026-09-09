import Foundation

protocol PluginExecutionBoundary: Sendable {
    func invoke(
        pluginID: String,
        capability: String,
        argumentsJSON: Data
    ) async throws -> Data
}

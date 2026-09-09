protocol CheckpointStoring: Sendable {
    func save(_ checkpoint: RuntimeCheckpoint) async throws
    func latest(streamID: String) async throws -> RuntimeCheckpoint?
}

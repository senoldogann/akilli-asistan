protocol EventStoring: Sendable {
    func append(_ event: RuntimeEvent) async throws
    func events(streamID: String, after sequence: UInt64) async throws -> [RuntimeEvent]
}

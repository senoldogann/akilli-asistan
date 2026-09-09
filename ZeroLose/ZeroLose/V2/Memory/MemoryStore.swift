protocol MemoryStoring: Sendable {
    func save(_ record: MemoryRecord) async throws
    func record(id: String) async throws -> MemoryRecord?
    func semantic(id: String) async throws -> SemanticMemoryRecord?
    func records(scope: MemoryScope) async throws -> [MemoryRecord]
}

struct ProceduralPromotionPolicy: Sendable {
    let minimumSuccesses: Int

    init(minimumSuccesses: Int) {
        self.minimumSuccesses = max(2, minimumSuccesses)
    }

    func shouldPromote(successes: Int, failures _: Int) -> Bool {
        successes >= minimumSuccesses
    }
}

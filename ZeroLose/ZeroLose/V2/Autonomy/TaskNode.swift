import Foundation

struct TaskNode: Codable, Equatable, Sendable {
    let id: TaskID
    let title: String
    var dependencies: Set<TaskID>
    var lifecycle: TaskLifecycle
    var verificationEvidence: [VerificationEvidence]
    var concurrencyClass: ConcurrencyClass

    init(
        id: TaskID,
        title: String,
        dependencies: Set<TaskID> = [],
        lifecycle: TaskLifecycle = .created,
        verificationEvidence: [VerificationEvidence] = [],
        concurrencyClass: ConcurrencyClass = .mutation
    ) {
        self.id = id
        self.title = title
        self.dependencies = dependencies
        self.lifecycle = lifecycle
        self.verificationEvidence = verificationEvidence
        self.concurrencyClass = concurrencyClass
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case dependencies
        case lifecycle
        case verificationEvidence
        case concurrencyClass
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TaskID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        dependencies = try container.decode(Set<TaskID>.self, forKey: .dependencies)
        lifecycle = try container.decode(TaskLifecycle.self, forKey: .lifecycle)
        verificationEvidence = try container.decode([VerificationEvidence].self, forKey: .verificationEvidence)
        concurrencyClass = try container.decodeIfPresent(ConcurrencyClass.self, forKey: .concurrencyClass) ?? .mutation
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(dependencies, forKey: .dependencies)
        try container.encode(lifecycle, forKey: .lifecycle)
        try container.encode(verificationEvidence, forKey: .verificationEvidence)
        try container.encode(concurrencyClass, forKey: .concurrencyClass)
    }
}

struct TaskGraphSnapshot: Codable, Equatable, Sendable {
    let goalID: GoalID
    let revision: UInt64
    let tasks: [TaskID: TaskNode]
}

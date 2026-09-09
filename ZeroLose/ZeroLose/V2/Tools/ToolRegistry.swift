struct ToolRegistrySnapshot: Sendable, Equatable {
    let revision: UInt64
    let descriptors: [ToolID: ToolDescriptor]
}

actor ToolRegistry {
    private var revision: UInt64 = 0
    private var descriptors: [ToolID: ToolDescriptor] = [:]

    func register(_ descriptor: ToolDescriptor) {
        revision &+= 1
        descriptors[descriptor.id] = descriptor
    }

    func revoke(_ id: ToolID) {
        guard descriptors.removeValue(forKey: id) != nil else {
            return
        }
        revision &+= 1
    }

    func resolve(_ id: ToolID) -> ToolDescriptor? {
        guard let descriptor = descriptors[id], descriptor.enabled else {
            return nil
        }
        return descriptor
    }

    func snapshot() -> ToolRegistrySnapshot {
        ToolRegistrySnapshot(revision: revision, descriptors: descriptors)
    }
}

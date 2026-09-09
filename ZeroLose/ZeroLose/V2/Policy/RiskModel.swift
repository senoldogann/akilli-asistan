enum AuthorityMode: String, Codable, Sendable {
    case manual
    case auto
    case autonomous
    case fullAccess
}

enum RiskLevel: Int, Codable, Comparable, Sendable {
    case readOnly = 0
    case reversibleLocalMutation = 1
    case externalCommunication = 2
    case highImpactExternalMutation = 3
    case irreversible = 4

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum EffectClass: String, Codable, Sendable {
    case read
    case reversibleLocalMutation
    case externalCommunication
    case highImpactExternalMutation
    case irreversible
}

struct PolicyContext: Sendable, Equatable {
    let authorityMode: AuthorityMode
    let declaredRisk: RiskLevel
    let effectClass: EffectClass
    let capabilityKnown: Bool
    let credentialScopeSatisfied: Bool
    let tainted: Bool
    let toolID: String?
    let taskID: TaskID?
    let destination: String?
    let argumentsDigest: String?
}

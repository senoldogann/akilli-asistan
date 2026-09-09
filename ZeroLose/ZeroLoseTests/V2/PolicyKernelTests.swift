import XCTest
@testable import ZeroLose

final class PolicyKernelTests: XCTestCase {
    func testUnknownCapabilityFailsClosed() async {
        let decision = await DefaultPolicyKernel().evaluate(.test(capabilityKnown: false))

        XCTAssertEqual(decision, .deny(reason: .unknownCapability))
    }

    func testFullAccessCannotBypassMissingCredentialScope() async {
        let decision = await DefaultPolicyKernel().evaluate(
            .test(authorityMode: .fullAccess, credentialScopeSatisfied: false)
        )

        XCTAssertEqual(decision, .deny(reason: .credentialScopeMissing))
    }

    func testIrreversibleEffectIsHardDeniedByDefault() async {
        let decision = await DefaultPolicyKernel().evaluate(
            .test(
                authorityMode: .fullAccess,
                declaredRisk: .readOnly,
                effectClass: .irreversible
            )
        )

        XCTAssertEqual(decision, .deny(reason: .hardPolicyDenied))
    }

    func testEffectClassRaisesEffectiveRiskFloor() async {
        let decision = await DefaultPolicyKernel().evaluate(
            .test(
                authorityMode: .auto,
                declaredRisk: .readOnly,
                effectClass: .externalCommunication
            )
        )

        XCTAssertEqual(decision, .deny(reason: .approvalRequired))
    }

    func testFullAccessPreGrantsHighImpactButNotIrreversibleRisk() async {
        let decision = await DefaultPolicyKernel().evaluate(
            .test(
                authorityMode: .fullAccess,
                declaredRisk: .highImpactExternalMutation,
                effectClass: .highImpactExternalMutation
            )
        )

        XCTAssertEqual(decision, .allow)
    }
}

private extension PolicyContext {
    static func test(
        authorityMode: AuthorityMode = .manual,
        declaredRisk: RiskLevel = .readOnly,
        effectClass: EffectClass = .read,
        capabilityKnown: Bool = true,
        credentialScopeSatisfied: Bool = true,
        tainted: Bool = false,
        toolID: String? = "test.tool",
        taskID: TaskID? = TaskID(rawValue: "task-1"),
        destination: String? = nil,
        argumentsDigest: String? = "digest"
    ) -> Self {
        Self(
            authorityMode: authorityMode,
            declaredRisk: declaredRisk,
            effectClass: effectClass,
            capabilityKnown: capabilityKnown,
            credentialScopeSatisfied: credentialScopeSatisfied,
            tainted: tainted,
            toolID: toolID,
            taskID: taskID,
            destination: destination,
            argumentsDigest: argumentsDigest
        )
    }
}

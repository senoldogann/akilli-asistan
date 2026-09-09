import Foundation
import XCTest
@testable import ZeroLose

final class ToolRegistryTests: XCTestCase {
    func testOldSnapshotDoesNotChangeAfterRegister() async {
        let registry = ToolRegistry()
        let before = await registry.snapshot()

        await registry.register(.test(id: "builtin.echo"))
        let after = await registry.snapshot()

        XCTAssertEqual(before.revision, 0)
        XCTAssertEqual(after.revision, 1)
        XCTAssertNil(before.descriptors[ToolID(rawValue: "builtin.echo")])
        XCTAssertNotNil(after.descriptors[ToolID(rawValue: "builtin.echo")])
    }

    func testRevokedToolCannotResolve() async {
        let registry = ToolRegistry()
        let id = ToolID(rawValue: "builtin.echo")

        await registry.register(.test(id: id.rawValue))
        await registry.revoke(id)

        let resolved = await registry.resolve(id)
        XCTAssertNil(resolved)
    }

    func testInvocationBindsRegistryDescriptorAndSchemaRevisions() {
        let invocation = ToolInvocation(
            invocationID: InvocationID(rawValue: "invocation-1"),
            toolID: ToolID(rawValue: "builtin.echo"),
            registryRevision: 7,
            descriptorRevision: 3,
            schemaDigest: "sha256:abc",
            argumentsJSON: Data("{}".utf8)
        )

        XCTAssertEqual(invocation.registryRevision, 7)
        XCTAssertEqual(invocation.descriptorRevision, 3)
        XCTAssertEqual(invocation.schemaDigest, "sha256:abc")
    }
}

private extension ToolDescriptor {
    static func test(id: String) -> Self {
        Self(
            id: ToolID(rawValue: id),
            providerID: "builtin",
            provenance: "test",
            descriptorRevision: 1,
            schemaDigest: "sha256:test",
            inputSchemaJSON: Data("{}".utf8),
            outputSchemaJSON: nil,
            effectClass: .read,
            declaredRisk: .readOnly,
            requiredCredentialScopes: [],
            idempotency: .none,
            concurrencyClass: .read,
            verificationContract: VerificationContract(kind: "none"),
            enabled: true
        )
    }
}

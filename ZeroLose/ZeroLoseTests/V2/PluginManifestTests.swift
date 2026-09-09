import Foundation
import XCTest
@testable import ZeroLose

final class PluginManifestTests: XCTestCase {
    func testManifestDecodesCapabilitiesAndScopes() throws {
        let data = Data(
            #"{"id":"github-workflows","version":"1.0.0","capabilities":["issues.create"],"credentialScopes":["github.issues.write"]}"#.utf8
        )

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertEqual(manifest.id, "github-workflows")
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.capabilities, ["issues.create"])
        XCTAssertEqual(manifest.credentialScopes, ["github.issues.write"])
    }

    func testPluginProviderExecutesOnlyThroughDeclarativeBoundary() async throws {
        let manifest = try makeManifest()
        let boundary = RecordingPluginExecutionBoundary()
        let provider = PluginToolProvider(manifest: manifest, boundary: boundary)
        let descriptor = ToolDescriptor.pluginTest(
            id: "plugin.github-workflows.issues.create",
            requiredCredentialScopes: ["github.issues.write"]
        )
        let argumentsJSON = Data(#"{"title":"Bug"}"#.utf8)
        let invocation = ToolInvocation.pluginTest(
            toolID: descriptor.id.rawValue,
            argumentsJSON: argumentsJSON
        )

        let receipt = try await provider.execute(
            descriptor: descriptor,
            invocation: invocation,
            credentialHandles: [
                CredentialHandle(scope: CredentialScope(rawValue: "github.issues.write")),
            ]
        )

        let invocationCount = await boundary.invocationCount
        let pluginID = await boundary.lastPluginID
        let capability = await boundary.lastCapability
        let receivedArguments = await boundary.lastArgumentsJSON

        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(pluginID, "github-workflows")
        XCTAssertEqual(capability, "issues.create")
        XCTAssertEqual(receivedArguments, argumentsJSON)
        XCTAssertEqual(receipt.invocationID, invocation.invocationID)
        XCTAssertEqual(receipt.toolID, descriptor.id)
    }

    func testPluginProviderRejectsMissingManifestCredentialScopeBeforeBoundary() async {
        let manifest: PluginManifest
        do {
            manifest = try makeManifest()
        } catch {
            XCTFail("Manifest setup failed: \(error)")
            return
        }

        let boundary = RecordingPluginExecutionBoundary()
        let provider = PluginToolProvider(manifest: manifest, boundary: boundary)
        let descriptor = ToolDescriptor.pluginTest(
            id: "plugin.github-workflows.issues.create",
            requiredCredentialScopes: []
        )
        let invocation = ToolInvocation.pluginTest(toolID: descriptor.id.rawValue)

        do {
            _ = try await provider.execute(
                descriptor: descriptor,
                invocation: invocation,
                credentialHandles: []
            )
            XCTFail("Expected missing manifest credential scope to fail closed")
        } catch let error as PluginToolProviderError {
            XCTAssertEqual(error, .credentialScopeMismatch)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let invocationCount = await boundary.invocationCount
        XCTAssertEqual(invocationCount, 0)
    }

    private func makeManifest() throws -> PluginManifest {
        let data = Data(
            #"{"id":"github-workflows","version":"1.0.0","capabilities":["issues.create"],"credentialScopes":["github.issues.write"]}"#.utf8
        )
        return try JSONDecoder().decode(PluginManifest.self, from: data)
    }
}

private actor RecordingPluginExecutionBoundary: PluginExecutionBoundary {
    private(set) var invocationCount = 0
    private(set) var lastPluginID: String?
    private(set) var lastCapability: String?
    private(set) var lastArgumentsJSON: Data?

    func invoke(
        pluginID: String,
        capability: String,
        argumentsJSON: Data
    ) async throws -> Data {
        invocationCount += 1
        lastPluginID = pluginID
        lastCapability = capability
        lastArgumentsJSON = argumentsJSON
        return Data(#"{"ok":true}"#.utf8)
    }
}

private extension ToolDescriptor {
    static func pluginTest(
        id: String,
        requiredCredentialScopes: Set<String>
    ) -> Self {
        Self(
            id: ToolID(rawValue: id),
            providerID: "plugin.github-workflows",
            provenance: "plugin:github-workflows@1.0.0",
            descriptorRevision: 1,
            schemaDigest: "sha256:test",
            inputSchemaJSON: Data("{}".utf8),
            outputSchemaJSON: nil,
            effectClass: .externalCommunication,
            declaredRisk: .externalCommunication,
            requiredCredentialScopes: requiredCredentialScopes,
            idempotency: .logicalOperationKeyRequired,
            concurrencyClass: .mutation,
            verificationContract: VerificationContract(kind: "plugin-result"),
            enabled: true
        )
    }
}

private extension ToolInvocation {
    static func pluginTest(
        toolID: String,
        argumentsJSON: Data = Data("{}".utf8)
    ) -> Self {
        Self(
            invocationID: InvocationID(rawValue: "invocation-plugin-test"),
            toolID: ToolID(rawValue: toolID),
            registryRevision: 1,
            descriptorRevision: 1,
            schemaDigest: "sha256:test",
            argumentsJSON: argumentsJSON
        )
    }
}

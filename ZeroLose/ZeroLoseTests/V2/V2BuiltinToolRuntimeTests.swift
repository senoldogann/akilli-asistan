import Foundation
import XCTest
@testable import ZeroLose

final class V2BuiltinToolRuntimeTests: XCTestCase {
    func testCatalogDeclaresReadOnlySystemStatusAndCredentialScopedWebSearch() {
        let descriptors = V2BuiltinToolCatalog.descriptors
        let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id.rawValue, $0) })

        let systemStatus = byID["builtin.system_status"]
        XCTAssertEqual(systemStatus?.effectClass, .read)
        XCTAssertEqual(systemStatus?.declaredRisk, .readOnly)
        XCTAssertEqual(systemStatus?.requiredCredentialScopes, [])
        XCTAssertTrue(systemStatus?.enabled == true)

        let webSearch = byID["builtin.web_search"]
        XCTAssertEqual(webSearch?.effectClass, .read)
        XCTAssertEqual(webSearch?.declaredRisk, .readOnly)
        XCTAssertEqual(webSearch?.requiredCredentialScopes, ["tavily.search"])
        XCTAssertTrue(webSearch?.enabled == true)
    }

    func testBuiltinExecutorRejectsWebSearchWithoutTavilyHandle() async throws {
        let executor = V2BuiltinToolExecutor(
            webSearch: { _ in "should not run" },
            systemStatus: { "status" }
        )
        guard let descriptor = V2BuiltinToolCatalog.descriptors.first(where: { $0.id.rawValue == "builtin.web_search" }) else {
            return XCTFail("Missing web-search descriptor")
        }
        let invocation = Self.invocation(for: descriptor, arguments: #"{"query":"Swift"}"#)

        do {
            _ = try await executor.executeBuiltin(
                descriptor: descriptor,
                invocation: invocation,
                credentialHandles: []
            )
            XCTFail("Expected credential rejection")
        } catch let error as V2BuiltinToolError {
            XCTAssertEqual(error, .missingCredentialScope("tavily.search"))
        }
    }

    func testBuiltinExecutorReturnsJSONPayloadForSystemStatus() async throws {
        let executor = V2BuiltinToolExecutor(
            webSearch: { _ in "unused" },
            systemStatus: { "CPU nominal" }
        )
        guard let descriptor = V2BuiltinToolCatalog.descriptors.first(where: { $0.id.rawValue == "builtin.system_status" }) else {
            return XCTFail("Missing system-status descriptor")
        }
        let invocation = Self.invocation(for: descriptor, arguments: "{}")

        let receipt = try await executor.executeBuiltin(
            descriptor: descriptor,
            invocation: invocation,
            credentialHandles: []
        )
        guard let resultJSON = receipt.resultJSON,
              let object = try JSONSerialization.jsonObject(with: resultJSON) as? [String: String] else {
            return XCTFail("Expected JSON result payload")
        }

        XCTAssertEqual(object["text"], "CPU nominal")
        XCTAssertEqual(receipt.resultProvenance, "builtin:system_status")
        XCTAssertFalse(receipt.resultTainted)
    }

    private static func invocation(for descriptor: ToolDescriptor, arguments: String) -> ToolInvocation {
        ToolInvocation(
            invocationID: InvocationID(rawValue: "builtin-test"),
            toolID: descriptor.id,
            registryRevision: 1,
            descriptorRevision: descriptor.descriptorRevision,
            schemaDigest: descriptor.schemaDigest,
            argumentsJSON: Data(arguments.utf8)
        )
    }
}

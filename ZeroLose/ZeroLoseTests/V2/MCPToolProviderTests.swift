import Foundation
import XCTest
@testable import ZeroLose

final class MCPToolProviderTests: XCTestCase {
    func testMCPToolUsesStableNamespace() throws {
        let descriptor = try MCPToolMapper(serverID: "gmail").descriptor(
            for: .test(name: "send_message")
        )

        XCTAssertEqual(descriptor.id.rawValue, "mcp.gmail.send_message")
        XCTAssertEqual(descriptor.providerID, "mcp.gmail")
        XCTAssertEqual(descriptor.provenance, "mcp:gmail")
    }

    func testReadOnlyHintCannotDowngradeKnownExternalEffect() throws {
        let descriptor = try MCPToolMapper(serverID: "gmail").descriptor(
            for: .test(name: "send_message", readOnlyHint: true)
        )

        XCTAssertEqual(descriptor.effectClass, .externalCommunication)
        XCTAssertEqual(descriptor.declaredRisk, .externalCommunication)
        XCTAssertEqual(descriptor.idempotency, .logicalOperationKeyRequired)
    }

    func testExplicitReadOnlyHintCanClassifyNonMutatingToolAsRead() throws {
        let descriptor = try MCPToolMapper(serverID: "gmail").descriptor(
            for: .test(name: "search_messages", readOnlyHint: true)
        )

        XCTAssertEqual(descriptor.effectClass, .read)
        XCTAssertEqual(descriptor.declaredRisk, .readOnly)
        XCTAssertEqual(descriptor.concurrencyClass, .read)
    }

    func testRefreshOnlyAdvancesRegistryWhenDiscoveryChanges() async throws {
        let registry = ToolRegistry()
        let client = RecordingMCPClient(
            tools: [
                .test(name: "search_messages", readOnlyHint: true),
                .test(name: "send_message", readOnlyHint: false),
            ]
        )
        let provider = MCPToolProvider(serverID: "gmail", client: client, registry: registry)

        try await provider.refresh()
        let firstSnapshot = await registry.snapshot()

        try await provider.refresh()
        let unchangedSnapshot = await registry.snapshot()
        XCTAssertEqual(unchangedSnapshot.revision, firstSnapshot.revision)

        await client.setTools([
            .test(name: "search_messages", readOnlyHint: true),
        ])
        try await provider.refresh()
        let changedSnapshot = await registry.snapshot()

        XCTAssertGreaterThan(changedSnapshot.revision, unchangedSnapshot.revision)
        XCTAssertNotNil(changedSnapshot.descriptors[ToolID(rawValue: "mcp.gmail.search_messages")])
        XCTAssertNil(changedSnapshot.descriptors[ToolID(rawValue: "mcp.gmail.send_message")])
    }
}

private actor RecordingMCPClient: MCPClient {
    private var tools: [MCPDiscoveredTool]

    init(tools: [MCPDiscoveredTool]) {
        self.tools = tools
    }

    func setTools(_ tools: [MCPDiscoveredTool]) {
        self.tools = tools
    }

    func listTools() async throws -> [MCPDiscoveredTool] {
        tools
    }

    func callTool(name: String, argumentsJSON: Data) async throws -> MCPToolResult {
        throw RecordingMCPClientError.unexpectedCall
    }
}

private enum RecordingMCPClientError: Error {
    case unexpectedCall
}

private extension MCPDiscoveredTool {
    static func test(
        name: String,
        readOnlyHint: Bool? = nil
    ) -> Self {
        Self(
            name: name,
            description: nil,
            inputSchemaJSON: Data("{}".utf8),
            outputSchemaJSON: nil,
            annotations: MCPToolAnnotations(
                readOnlyHint: readOnlyHint,
                destructiveHint: nil,
                idempotentHint: nil,
                openWorldHint: nil
            )
        )
    }
}

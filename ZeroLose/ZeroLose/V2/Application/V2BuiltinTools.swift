import CryptoKit
import Foundation

enum V2BuiltinToolError: Error, Equatable {
    case unsupportedTool(String)
    case invalidArguments(String)
    case missingCredentialScope(String)
}

enum V2BuiltinToolCatalog {
    static let descriptors: [ToolDescriptor] = [
        makeDescriptor(
            id: "builtin.system_status",
            inputSchemaJSON: Data(
                #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#.utf8
            ),
            requiredCredentialScopes: []
        ),
        makeDescriptor(
            id: "builtin.web_search",
            inputSchemaJSON: Data(
                #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}"#.utf8
            ),
            requiredCredentialScopes: ["tavily.search"]
        )
    ]

    private static func makeDescriptor(
        id: String,
        inputSchemaJSON: Data,
        requiredCredentialScopes: Set<String>
    ) -> ToolDescriptor {
        ToolDescriptor(
            id: ToolID(rawValue: id),
            providerID: "builtin",
            provenance: "zerolose:v2:builtin",
            descriptorRevision: 1,
            schemaDigest: digest(inputSchemaJSON),
            inputSchemaJSON: inputSchemaJSON,
            outputSchemaJSON: Data(
                #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}"#.utf8
            ),
            effectClass: .read,
            declaredRisk: .readOnly,
            requiredCredentialScopes: requiredCredentialScopes,
            idempotency: .none,
            concurrencyClass: .read,
            verificationContract: VerificationContract(kind: "read-result"),
            enabled: true
        )
    }

    private static func digest(_ input: Data) -> String {
        let hash = SHA256.hash(data: input)
        return "sha256:" + hash.map { String(format: "%02x", $0) }.joined()
    }
}

struct V2BuiltinToolExecutor: BuiltinToolExecuting {
    typealias WebSearch = @Sendable (String) async throws -> String
    typealias SystemStatus = @Sendable () async -> String

    private let webSearch: WebSearch
    private let systemStatus: SystemStatus

    init(
        webSearch: @escaping WebSearch,
        systemStatus: @escaping SystemStatus
    ) {
        self.webSearch = webSearch
        self.systemStatus = systemStatus
    }

    func executeBuiltin(
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        credentialHandles: [CredentialHandle]
    ) async throws -> ToolExecutionReceipt {
        guard descriptor.providerID == "builtin", descriptor.id == invocation.toolID else {
            throw V2BuiltinToolError.unsupportedTool(invocation.toolID.rawValue)
        }

        let startedAt = Date()
        switch descriptor.id.rawValue {
        case "builtin.system_status":
            let text = await systemStatus()
            return makeReceipt(
                descriptor: descriptor,
                invocation: invocation,
                startedAt: startedAt,
                text: text,
                provenance: "builtin:system_status",
                tainted: false
            )

        case "builtin.web_search":
            let requiredScope = "tavily.search"
            guard credentialHandles.contains(where: { $0.scope.rawValue == requiredScope }) else {
                throw V2BuiltinToolError.missingCredentialScope(requiredScope)
            }

            struct SearchArguments: Decodable {
                let query: String
            }
            guard let arguments = try? JSONDecoder().decode(
                SearchArguments.self,
                from: invocation.argumentsJSON
            ) else {
                throw V2BuiltinToolError.invalidArguments(descriptor.id.rawValue)
            }
            let query = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                throw V2BuiltinToolError.invalidArguments(descriptor.id.rawValue)
            }

            let text = try await webSearch(query)
            return makeReceipt(
                descriptor: descriptor,
                invocation: invocation,
                startedAt: startedAt,
                text: text,
                provenance: "builtin:web_search:external",
                tainted: true
            )

        default:
            throw V2BuiltinToolError.unsupportedTool(descriptor.id.rawValue)
        }
    }

    private func makeReceipt(
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        startedAt: Date,
        text: String,
        provenance: String,
        tainted: Bool
    ) -> ToolExecutionReceipt {
        let resultJSON = try? JSONSerialization.data(
            withJSONObject: ["text": text],
            options: [.sortedKeys]
        )
        return ToolExecutionReceipt(
            invocationID: invocation.invocationID,
            toolID: descriptor.id,
            startedAt: startedAt,
            completedAt: Date(),
            providerReference: nil,
            resultProvenance: provenance,
            resultJSON: resultJSON,
            resultTainted: tainted
        )
    }
}

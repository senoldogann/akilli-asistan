import CryptoKit
import Foundation

enum MCPToolMapperError: Error, Equatable {
    case invalidServerID
    case invalidToolName
}

struct MCPToolMapper {
    let serverID: String

    init(serverID: String) {
        self.serverID = serverID
    }

    func descriptor(
        for tool: MCPDiscoveredTool,
        descriptorRevision: UInt64 = 1
    ) throws -> ToolDescriptor {
        guard isStableNamespaceComponent(serverID) else {
            throw MCPToolMapperError.invalidServerID
        }
        guard isStableToolName(tool.name) else {
            throw MCPToolMapperError.invalidToolName
        }

        let providerID = "mcp.\(serverID)"
        let toolID = ToolID(rawValue: "\(providerID).\(tool.name)")
        let effect = classifyEffect(tool)
        let isRead = effect == .read

        return ToolDescriptor(
            id: toolID,
            providerID: providerID,
            provenance: "mcp:\(serverID)",
            descriptorRevision: descriptorRevision,
            schemaDigest: schemaDigest(
                input: tool.inputSchemaJSON,
                output: tool.outputSchemaJSON
            ),
            inputSchemaJSON: tool.inputSchemaJSON,
            outputSchemaJSON: tool.outputSchemaJSON,
            effectClass: effect,
            declaredRisk: isRead ? .readOnly : .externalCommunication,
            requiredCredentialScopes: [],
            idempotency: isRead ? .none : .logicalOperationKeyRequired,
            concurrencyClass: isRead ? .read : .mutation,
            verificationContract: VerificationContract(
                kind: isRead ? "mcp-read-result" : "mcp-external-mutation-result"
            ),
            enabled: true
        )
    }

    private func classifyEffect(_ tool: MCPDiscoveredTool) -> EffectClass {
        if isKnownExternalMutation(tool.name) {
            return .externalCommunication
        }

        if tool.annotations.readOnlyHint == true {
            return .read
        }

        return .externalCommunication
    }

    private func isKnownExternalMutation(_ name: String) -> Bool {
        let mutationVerbs: Set<String> = [
            "send", "create", "update", "delete", "remove", "publish", "post",
            "write", "upload", "submit", "reply", "forward", "invite", "merge",
            "close", "reopen", "cancel", "purchase", "pay", "transfer",
        ]

        let lowercased = name.lowercased()
        if mutationVerbs.contains(where: { lowercased.hasPrefix($0) }) {
            return true
        }

        let tokens = lowercased.split { character in
            !character.isLetter && !character.isNumber
        }
        return tokens.contains { mutationVerbs.contains(String($0)) }
    }

    private func isStableNamespaceComponent(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-"
                || scalar == "_"
        }
    }

    private func isStableToolName(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-"
                || scalar == "_"
                || scalar == "."
        }
    }

    private func schemaDigest(input: Data, output: Data?) -> String {
        var hasher = SHA256()
        hasher.update(data: input)
        hasher.update(data: Data([0]))
        if let output {
            hasher.update(data: output)
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }
}

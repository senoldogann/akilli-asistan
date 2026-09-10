import Foundation

struct V2NativeToolConfiguration: Sendable {
    let tools: [AgentFunctionTool]
    let executor: AgentToolExecutor
}

actor V2NativeToolRuntime: ToolManagementControlling {
    private let registry: ToolRegistry
    private let toolFabric: ToolFabric
    private let initialDescriptors: [ToolDescriptor]
    private var didBootstrap = false

    init(
        registry: ToolRegistry,
        toolFabric: ToolFabric,
        initialDescriptors: [ToolDescriptor] = []
    ) {
        self.registry = registry
        self.toolFabric = toolFabric
        self.initialDescriptors = initialDescriptors
    }

    func configuration() async -> V2NativeToolConfiguration {
        await bootstrapIfNeeded()
        let snapshot = await registry.snapshot()
        let visibleDescriptors = snapshot.descriptors.values
            .filter(\.enabled)
            .sorted { $0.id.rawValue < $1.id.rawValue }

        var descriptorsByFunctionName: [String: ToolDescriptor] = [:]
        var tools: [AgentFunctionTool] = []
        tools.reserveCapacity(visibleDescriptors.count)

        for descriptor in visibleDescriptors {
            guard let tool = Self.makeAgentFunctionTool(from: descriptor) else {
                continue
            }
            descriptorsByFunctionName[tool.function.name] = descriptor
            tools.append(tool)
        }

        let registryRevision = snapshot.revision
        let descriptorsByName = descriptorsByFunctionName
        let toolFabric = self.toolFabric
        let executor: AgentToolExecutor = { call in
            guard let descriptor = descriptorsByName[call.name] else {
                return Self.errorJSON(
                    code: "unknown_tool",
                    detail: call.name
                )
            }

            guard let arguments = call.argumentsJSON.data(using: .utf8),
                  Self.isJSONObject(arguments) else {
                return Self.errorJSON(
                    code: "invalid_arguments_json",
                    detail: descriptor.id.rawValue
                )
            }

            let logicalOperationKey: String?
            if descriptor.idempotency == .logicalOperationKeyRequired {
                let normalizedCallID = call.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedCallID.isEmpty else {
                    return Self.errorJSON(
                        code: "missing_logical_operation_key",
                        detail: descriptor.id.rawValue
                    )
                }
                logicalOperationKey = normalizedCallID
            } else {
                logicalOperationKey = nil
            }

            let invocation = ToolInvocation(
                invocationID: InvocationID(rawValue: call.id),
                toolID: descriptor.id,
                registryRevision: registryRevision,
                descriptorRevision: descriptor.descriptorRevision,
                schemaDigest: descriptor.schemaDigest,
                argumentsJSON: arguments,
                logicalOperationKey: logicalOperationKey
            )

            do {
                let receipt = try await toolFabric.execute(invocation)
                return Self.successJSON(receipt)
            } catch let error as ToolFabricError {
                return Self.toolFabricErrorJSON(error)
            } catch {
                return Self.errorJSON(
                    code: "tool_execution_failed",
                    detail: String(describing: error)
                )
            }
        }

        return V2NativeToolConfiguration(tools: tools, executor: executor)
    }

    func setToolEnabled(_ toolID: ToolID, enabled: Bool) async throws {
        await bootstrapIfNeeded()
        let snapshot = await registry.snapshot()
        guard let current = snapshot.descriptors[toolID] else {
            throw ToolFabricError.unknownTool(toolID)
        }

        guard current.enabled != enabled else { return }
        await registry.register(Self.copy(current, enabled: enabled))
    }

    func setMCPServerEnabled(_ serverID: String, enabled: Bool) async throws {
        await bootstrapIfNeeded()
        let normalized = serverID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw V2RuntimeCommandError.unsupportedCommand("mcp-empty-server-id")
        }

        let snapshot = await registry.snapshot()
        let prefix = "mcp.\(normalized)."
        let matching = snapshot.descriptors.values
            .filter { $0.id.rawValue.hasPrefix(prefix) }

        guard !matching.isEmpty else {
            throw V2RuntimeCommandError.unsupportedCommand("mcp:\(normalized):not-configured")
        }

        for descriptor in matching where descriptor.enabled != enabled {
            await registry.register(Self.copy(descriptor, enabled: enabled))
        }
    }

    func setAuthorityMode(_ mode: AuthorityMode) async {
        await toolFabric.setAuthorityMode(mode)
    }

    private func bootstrapIfNeeded() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        guard !initialDescriptors.isEmpty else { return }
        let snapshot = await registry.snapshot()
        for descriptor in initialDescriptors where snapshot.descriptors[descriptor.id] == nil {
            await registry.register(descriptor)
        }
    }

    private static func copy(_ descriptor: ToolDescriptor, enabled: Bool) -> ToolDescriptor {
        ToolDescriptor(
            id: descriptor.id,
            providerID: descriptor.providerID,
            provenance: descriptor.provenance,
            descriptorRevision: descriptor.descriptorRevision &+ 1,
            schemaDigest: descriptor.schemaDigest,
            inputSchemaJSON: descriptor.inputSchemaJSON,
            outputSchemaJSON: descriptor.outputSchemaJSON,
            effectClass: descriptor.effectClass,
            declaredRisk: descriptor.declaredRisk,
            requiredCredentialScopes: descriptor.requiredCredentialScopes,
            idempotency: descriptor.idempotency,
            concurrencyClass: descriptor.concurrencyClass,
            verificationContract: descriptor.verificationContract,
            enabled: enabled
        )
    }

    private static func makeAgentFunctionTool(from descriptor: ToolDescriptor) -> AgentFunctionTool? {
        guard let object = try? JSONSerialization.jsonObject(with: descriptor.inputSchemaJSON),
              let schema = object as? [String: Any],
              let type = schema["type"] as? String,
              type == "object" else {
            return nil
        }

        let propertiesObject = schema["properties"] as? [String: Any] ?? [:]
        var properties: [String: AgentFunctionTool.JSONValue] = [:]
        for (key, value) in propertiesObject {
            guard let converted = jsonValue(value) else { continue }
            properties[key] = converted
        }

        let required = schema["required"] as? [String] ?? []
        let additionalProperties = schema["additionalProperties"] as? Bool ?? false

        return AgentFunctionTool(
            type: "function",
            function: .init(
                name: functionName(for: descriptor.id),
                description: "V2 tool \(descriptor.id.rawValue) from \(descriptor.provenance)",
                parameters: .init(
                    type: "object",
                    properties: properties,
                    required: required,
                    additionalProperties: additionalProperties
                )
            )
        )
    }

    private static func functionName(for toolID: ToolID) -> String {
        toolID.rawValue.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
                ? String(scalar)
                : "__"
        }.joined()
    }

    private static func jsonValue(_ value: Any) -> AgentFunctionTool.JSONValue? {
        switch value {
        case let string as String:
            return .string(string)
        case let bool as Bool:
            return .boolean(bool)
        case let number as NSNumber:
            return .number(number.doubleValue)
        case let object as [String: Any]:
            var converted: [String: AgentFunctionTool.JSONValue] = [:]
            for (key, nested) in object {
                guard let nestedValue = jsonValue(nested) else { continue }
                converted[key] = nestedValue
            }
            return .object(converted)
        case let array as [Any]:
            return .array(array.compactMap(jsonValue))
        case _ as NSNull:
            return .null
        default:
            return nil
        }
    }

    private static func isJSONObject(_ data: Data) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return value is [String: Any]
    }

    private static func successJSON(_ receipt: ToolExecutionReceipt) -> String {
        var object: [String: Any] = [
            "ok": true,
            "tool_id": receipt.toolID.rawValue,
            "tainted": receipt.resultTainted
        ]

        if let providerReference = receipt.providerReference {
            object["provider_reference"] = providerReference
        }
        if let provenance = receipt.resultProvenance {
            object["provenance"] = provenance
        }
        if let resultJSON = receipt.resultJSON,
           let result = try? JSONSerialization.jsonObject(with: resultJSON) {
            object["result"] = result
        }

        return serializedJSONObject(object)
    }

    private static func toolFabricErrorJSON(_ error: ToolFabricError) -> String {
        switch error {
        case .unknownTool(let id):
            return errorJSON(code: "unknown_tool", detail: id.rawValue)
        case .staleRegistryRevision:
            return errorJSON(code: "stale_registry_revision", detail: nil)
        case .staleDescriptorRevision:
            return errorJSON(code: "stale_descriptor_revision", detail: nil)
        case .schemaDigestMismatch:
            return errorJSON(code: "schema_digest_mismatch", detail: nil)
        case .missingLogicalOperationKey:
            return errorJSON(code: "missing_logical_operation_key", detail: nil)
        case .policyDenied(let reason):
            return errorJSON(code: "policy_denied", detail: reason.rawValue)
        }
    }

    private static func errorJSON(code: String, detail: String?) -> String {
        var object: [String: Any] = ["ok": false, "error": code]
        if let detail, !detail.isEmpty {
            object["detail"] = detail
        }
        return serializedJSONObject(object)
    }

    private static func serializedJSONObject(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"error":"serialization_failed"}"#
        }
        return string
    }
}

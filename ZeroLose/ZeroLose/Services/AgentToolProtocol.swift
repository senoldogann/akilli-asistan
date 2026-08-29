import Foundation

/// Provider-neutral representation of a model-requested tool call.
struct AgentToolCall: Sendable, Equatable {
    let id: String
    let name: String
    let argumentsJSON: String

    init(id: String = UUID().uuidString, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    var arguments: [String: Any]? {
        guard let data = argumentsJSON.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Executes one native tool call and returns a text result that is fed back
/// to the model as a `tool` message in the next round.
typealias AgentToolExecutor = @Sendable (AgentToolCall) async -> String

/// OpenAI-compatible function tool schema. DeepSeek and OpenCode can consume
/// this shape when native tool calling is enabled by the selected model.
struct AgentFunctionTool: Encodable, Sendable, Equatable {
    let type: String
    let function: Function

    struct Function: Encodable, Sendable, Equatable {
        let name: String
        let description: String
        let parameters: JSONSchema
    }

    struct JSONSchema: Encodable, Sendable, Equatable {
        let type: String
        let properties: [String: JSONValue]
        let required: [String]
        let additionalProperties: Bool
    }

    enum JSONValue: Encodable, Sendable, Equatable {
        case string(String)
        case object([String: JSONValue])
        case array([JSONValue])
        case boolean(Bool)
        case number(Double)
        case null

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .boolean(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }
    }
}

extension AgentCapabilityRegistry {
    /// Emits schemas for native function calling. The legacy ACTION examples
    /// remain in the prompt as a fallback for providers without native tools.
    nonisolated static func structuredTools() -> [AgentFunctionTool] {
        all.map { capability in
            AgentFunctionTool(
                type: "function",
                function: .init(
                    name: capability.actionType,
                    description: "\(capability.summary) Kullan: \(capability.whenToUse)",
                    parameters: .init(
                        type: "object",
                        properties: [
                            "payload": .string("Tool-specific arguments for \(capability.actionType)")
                        ],
                        required: [],
                        additionalProperties: true
                    )
                )
            )
        }
    }
}

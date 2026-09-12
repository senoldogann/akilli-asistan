import Foundation

enum ComputerInvocationFreshnessBinderError: Error, Sendable, Equatable {
    case invalidArguments
    case reservedFreshnessField
}

struct ComputerInvocationFreshnessBinder: Sendable {
    func bind(
        argumentsJSON: Data,
        state: ComputerMutationState
    ) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any] else {
            throw ComputerInvocationFreshnessBinderError.invalidArguments
        }
        guard object["stateVersion"] == nil,
              object["observationID"] == nil else {
            throw ComputerInvocationFreshnessBinderError.reservedFreshnessField
        }

        object["stateVersion"] = state.stateVersion
        object["observationID"] = state.observationID
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ComputerInvocationFreshnessBinderError.invalidArguments
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

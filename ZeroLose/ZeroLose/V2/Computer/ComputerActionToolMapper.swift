import Foundation

enum ToolFabricComputerAction: Sendable, Equatable {
    case click(x: Double, y: Double)
    case type(String)
}

struct ComputerMutationState: Sendable, Equatable {
    let stateVersion: UInt64
    let observationID: String
}

struct ComputerActionToolMapping: Sendable, Equatable {
    let toolID: ToolID
    let argumentsJSON: Data
}

enum ComputerActionToolMapperError: Error, Equatable {
    case invalidObservationID
    case invalidCoordinate
    case encodingFailed
}

struct ComputerActionToolMapper: Sendable {
    func map(
        _ action: ToolFabricComputerAction,
        state: ComputerMutationState
    ) throws -> ComputerActionToolMapping {
        guard !state.observationID.isEmpty else {
            throw ComputerActionToolMapperError.invalidObservationID
        }

        switch action {
        case .click(let x, let y):
            guard x.isFinite, y.isFinite else {
                throw ComputerActionToolMapperError.invalidCoordinate
            }
            return ComputerActionToolMapping(
                toolID: ToolID(rawValue: "computer.pointer.click"),
                argumentsJSON: try encode(
                    ClickArguments(
                        stateVersion: state.stateVersion,
                        observationID: state.observationID,
                        x: x,
                        y: y
                    )
                )
            )

        case .type(let text):
            return ComputerActionToolMapping(
                toolID: ToolID(rawValue: "computer.keyboard.type"),
                argumentsJSON: try encode(
                    TypeArguments(
                        stateVersion: state.stateVersion,
                        observationID: state.observationID,
                        text: text
                    )
                )
            )
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw ComputerActionToolMapperError.encodingFailed
        }
    }
}

private struct ClickArguments: Encodable {
    let stateVersion: UInt64
    let observationID: String
    let x: Double
    let y: Double
}

private struct TypeArguments: Encodable {
    let stateVersion: UInt64
    let observationID: String
    let text: String
}

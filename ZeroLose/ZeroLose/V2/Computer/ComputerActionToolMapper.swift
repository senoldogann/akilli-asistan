import Foundation

enum ToolFabricComputerAction: Sendable, Equatable {
    case click(x: Double, y: Double)
    case type(String)
    case pressKey(String)
    case scroll(amount: Int)
    case wait(milliseconds: Int)
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
    case invalidScrollAmount
    case invalidWaitDuration
    case unsupportedKey(String)
    case encodingFailed
}

struct ComputerActionToolMapper: Sendable {
    static let scrollRange = -1400...1400
    static let waitRange = 0...5000
    static let supportedKeys: Set<String> = [
        "return", "enter", "tab", "space", "delete", "backspace",
        "escape", "esc", "home", "pageup", "page_up", "end",
        "pagedown", "page_down", "left", "arrowleft", "arrow_left",
        "right", "arrowright", "arrow_right", "down", "arrowdown",
        "arrow_down", "up", "arrowup", "arrow_up",
    ]

    func map(
        _ action: ToolFabricComputerAction,
        state: ComputerMutationState
    ) throws -> ComputerActionToolMapping {
        let observationID = state.observationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !observationID.isEmpty else {
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
                        observationID: observationID,
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
                        observationID: observationID,
                        text: text
                    )
                )
            )

        case .pressKey(let rawKey):
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard Self.supportedKeys.contains(key) else {
                throw ComputerActionToolMapperError.unsupportedKey(rawKey)
            }
            return ComputerActionToolMapping(
                toolID: ToolID(rawValue: "computer.keyboard.press"),
                argumentsJSON: try encode(
                    KeyArguments(
                        stateVersion: state.stateVersion,
                        observationID: observationID,
                        key: key
                    )
                )
            )

        case .scroll(let amount):
            guard Self.scrollRange.contains(amount) else {
                throw ComputerActionToolMapperError.invalidScrollAmount
            }
            return ComputerActionToolMapping(
                toolID: ToolID(rawValue: "computer.scroll"),
                argumentsJSON: try encode(
                    ScrollArguments(
                        stateVersion: state.stateVersion,
                        observationID: observationID,
                        amount: amount
                    )
                )
            )

        case .wait(let milliseconds):
            guard Self.waitRange.contains(milliseconds) else {
                throw ComputerActionToolMapperError.invalidWaitDuration
            }
            return ComputerActionToolMapping(
                toolID: ToolID(rawValue: "computer.wait"),
                argumentsJSON: try encode(
                    WaitArguments(
                        stateVersion: state.stateVersion,
                        observationID: observationID,
                        milliseconds: milliseconds
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

private struct KeyArguments: Encodable {
    let stateVersion: UInt64
    let observationID: String
    let key: String
}

private struct ScrollArguments: Encodable {
    let stateVersion: UInt64
    let observationID: String
    let amount: Int
}

private struct WaitArguments: Encodable {
    let stateVersion: UInt64
    let observationID: String
    let milliseconds: Int
}

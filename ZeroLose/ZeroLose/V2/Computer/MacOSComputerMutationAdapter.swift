@preconcurrency import ExamPilotCore
import CoreGraphics
import Foundation


struct ExamPilotAgentComputerOutcomeVerifier: AgentComputerOutcomeVerifying, @unchecked Sendable {
    private let verifier: OutcomeVerifier

    init(verifier: OutcomeVerifier = OutcomeVerifier()) {
        self.verifier = verifier
    }

    func verify(
        expectation: VerificationExpectation,
        before: CGImage,
        after: CGImage,
        uiStable: Bool
    ) -> Bool {
        let expected: ExpectedOutcomeKind
        switch expectation {
        case .computerNone:
            expected = .none
        case .computerAnswerMutation:
            expected = .answerMutation
        case .computerViewportChange:
            expected = .viewportChange
        case .computerNavigation:
            expected = .navigation
        case .readResult:
            return false
        }

        if case .success = verifier.verify(
            expected: expected,
            before: before,
            after: after,
            uiStable: uiStable
        ) {
            return true
        }
        return false
    }
}

enum MacOSComputerMutationAdapterError: Error, Equatable {
    case invalidArguments
    case staleState
    case unsupportedAction(String)
}

final class MacOSComputerMutationAdapter: ComputerMutationGating, @unchecked Sendable {
    private let inputDriver: any InputDriving
    private let stateProvider: any ComputerMutationStateProviding
    private let mapper: ComputerActionToolMapper

    init(
        inputDriver: any InputDriving,
        stateProvider: any ComputerMutationStateProviding,
        mapper: ComputerActionToolMapper = ComputerActionToolMapper()
    ) {
        self.inputDriver = inputDriver
        self.stateProvider = stateProvider
        self.mapper = mapper
    }

    convenience init(
        stateProvider: any ComputerMutationStateProviding,
        shouldStop: @escaping () -> Bool
    ) {
        self.init(
            inputDriver: NativeInputDriver(shouldStop: shouldStop),
            stateProvider: stateProvider
        )
    }

    func executePhysicalProposal(
        _ proposal: ComputerPhysicalProposal,
        parentInvocationID: InvocationID
    ) async throws -> ToolExecutionReceipt {
        let action = try validatedAction(from: proposal)
        let latestState = try await stateProvider.currentComputerMutationState()

        guard latestState.stateVersion == proposal.stateVersion,
              latestState.observationID == proposal.observationID else {
            throw MacOSComputerMutationAdapterError.staleState
        }

        let startedAt = Date()
        switch action {
        case .click(let x, let y):
            try await inputDriver.moveAndClick(x: x, y: y)
        case .type(let text):
            try await inputDriver.typeText(text)
        case .pressKey(let key):
            try await inputDriver.pressKey(key)
        case .scroll(let amount):
            try await inputDriver.scroll(amount: amount)
        case .wait(let milliseconds):
            try await inputDriver.wait(milliseconds: milliseconds)
        }

        return ToolExecutionReceipt(
            invocationID: parentInvocationID,
            toolID: ToolID(rawValue: "computer.\(proposal.action)"),
            startedAt: startedAt,
            completedAt: Date(),
            providerReference: "macos-native-input",
            resultProvenance: "computer-mutation-adapter"
        )
    }

    private func validatedAction(
        from proposal: ComputerPhysicalProposal
    ) throws -> ToolFabricComputerAction {
        let observationID = proposal.observationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !observationID.isEmpty,
              observationID == proposal.observationID,
              let metadata = try? JSONDecoder().decode(
                  ProposalMetadata.self,
                  from: proposal.argumentsJSON
              ),
              metadata.stateVersion == proposal.stateVersion,
              metadata.observationID == proposal.observationID else {
            throw MacOSComputerMutationAdapterError.invalidArguments
        }

        let action: ToolFabricComputerAction
        switch proposal.action {
        case "pointer.click":
            guard let arguments = try? JSONDecoder().decode(
                ClickArguments.self,
                from: proposal.argumentsJSON
            ) else {
                throw MacOSComputerMutationAdapterError.invalidArguments
            }
            action = .click(x: arguments.x, y: arguments.y)

        case "keyboard.type":
            guard let arguments = try? JSONDecoder().decode(
                TypeArguments.self,
                from: proposal.argumentsJSON
            ) else {
                throw MacOSComputerMutationAdapterError.invalidArguments
            }
            action = .type(arguments.text)

        case "keyboard.press":
            guard let arguments = try? JSONDecoder().decode(
                KeyArguments.self,
                from: proposal.argumentsJSON
            ) else {
                throw MacOSComputerMutationAdapterError.invalidArguments
            }
            action = .pressKey(
                arguments.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )

        case "scroll":
            guard let arguments = try? JSONDecoder().decode(
                ScrollArguments.self,
                from: proposal.argumentsJSON
            ) else {
                throw MacOSComputerMutationAdapterError.invalidArguments
            }
            action = .scroll(amount: arguments.amount)

        case "wait":
            guard let arguments = try? JSONDecoder().decode(
                WaitArguments.self,
                from: proposal.argumentsJSON
            ) else {
                throw MacOSComputerMutationAdapterError.invalidArguments
            }
            action = .wait(milliseconds: arguments.milliseconds)

        default:
            throw MacOSComputerMutationAdapterError.unsupportedAction(proposal.action)
        }

        do {
            let mapping = try mapper.map(
                action,
                state: ComputerMutationState(
                    stateVersion: proposal.stateVersion,
                    observationID: proposal.observationID
                )
            )
            guard mapping.toolID.rawValue == "computer.\(proposal.action)" else {
                throw MacOSComputerMutationAdapterError.invalidArguments
            }
        } catch is MacOSComputerMutationAdapterError {
            throw MacOSComputerMutationAdapterError.invalidArguments
        } catch {
            throw MacOSComputerMutationAdapterError.invalidArguments
        }

        return action
    }
}

private struct ProposalMetadata: Decodable {
    let stateVersion: UInt64
    let observationID: String
}

private struct ClickArguments: Decodable {
    let x: Double
    let y: Double
}

private struct TypeArguments: Decodable {
    let text: String
}

private struct KeyArguments: Decodable {
    let key: String
}

private struct ScrollArguments: Decodable {
    let amount: Int
}

private struct WaitArguments: Decodable {
    let milliseconds: Int
}

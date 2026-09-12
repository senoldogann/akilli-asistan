import Foundation

enum VerificationExpectation: String, Codable, Sendable, Equatable {
    case readResult
    case computerNone
    case computerAnswerMutation
    case computerViewportChange
    case computerNavigation

    func isCompatible(
        toolID: ToolID,
        verificationContract: VerificationContract
    ) -> Bool {
        Self.supported(
            toolID: toolID,
            verificationContract: verificationContract
        ).contains(self)
    }

    static func supported(
        toolID: ToolID,
        verificationContract: VerificationContract
    ) -> [VerificationExpectation] {
        switch verificationContract.kind {
        case "read-result":
            return [.readResult]

        case "fresh-computer-observation":
            switch toolID.rawValue {
            case "computer.wait":
                return [.computerNone]
            case "computer.scroll":
                return [.computerViewportChange]
            case "computer.keyboard.type":
                return [.computerAnswerMutation]
            case "computer.pointer.click", "computer.keyboard.press":
                return [.computerAnswerMutation, .computerNavigation]
            default:
                return []
            }

        default:
            return []
        }
    }

}

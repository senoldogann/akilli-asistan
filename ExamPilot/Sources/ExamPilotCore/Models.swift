import Foundation
import CoreGraphics

public struct ScreenFrame {
    public let image: CGImage
    public let jpegData: Data
    public let screenBounds: CGRect
    public let targetProcessID: Int32?

    public init(
        image: CGImage,
        jpegData: Data,
        screenBounds: CGRect,
        targetProcessID: Int32? = nil
    ) {
        self.image = image
        self.jpegData = jpegData
        self.screenBounds = screenBounds
        self.targetProcessID = targetProcessID
    }

    public var pixelWidth: Int { image.width }
    public var pixelHeight: Int { image.height }
}

public enum ExamActionKind: String, Codable, CaseIterable {
    case moveClick = "move_click"
    case typeText = "type_text"
    case key
    case scroll
    case wait
    case finish
}

public enum SupportedInputKey: String, CaseIterable {
    case returnKey = "return"
    case enter
    case tab
    case space
    case delete
    case backspace
    case escape
    case esc
    case home
    case pageup
    case pageUp = "page_up"
    case end
    case pagedown
    case pageDown = "page_down"
    case left
    case arrowleft
    case arrowLeft = "arrow_left"
    case right
    case arrowright
    case arrowRight = "arrow_right"
    case down
    case arrowdown
    case arrowDown = "arrow_down"
    case up
    case arrowup
    case arrowUp = "arrow_up"
}

public struct ExamAction: Codable, Equatable {
    public var kind: ExamActionKind
    public var x: Double?
    public var y: Double?
    public var text: String?
    public var key: String?
    public var amount: Int?
    public var milliseconds: Int?
    public var boundary: Bool

    public init(
        kind: ExamActionKind,
        x: Double? = nil,
        y: Double? = nil,
        text: String? = nil,
        key: String? = nil,
        amount: Int? = nil,
        milliseconds: Int? = nil,
        boundary: Bool = false
    ) {
        self.kind = kind
        self.x = x
        self.y = y
        self.text = text
        self.key = key
        self.amount = amount
        self.milliseconds = milliseconds
        self.boundary = boundary
    }

    public static func moveClick(x: Double, y: Double, boundary: Bool = false) -> Self {
        Self(kind: .moveClick, x: x, y: y, boundary: boundary)
    }

    public static func typeText(_ text: String, boundary: Bool = false) -> Self {
        Self(kind: .typeText, text: text, boundary: boundary)
    }

    public static func pressKey(_ key: String, boundary: Bool = false) -> Self {
        Self(kind: .key, key: key, boundary: boundary)
    }

    public static func scroll(amount: Int, boundary: Bool = false) -> Self {
        Self(kind: .scroll, amount: amount, boundary: boundary)
    }

    public static func wait(milliseconds: Int, boundary: Bool = false) -> Self {
        Self(kind: .wait, milliseconds: milliseconds, boundary: boundary)
    }

    public static func finish() -> Self {
        Self(kind: .finish, boundary: true)
    }
}

public struct ExamDecision: Codable, Equatable {
    public var summary: String
    public var expectsVisualChange: Bool
    public var actions: [ExamAction]

    public init(summary: String, expectsVisualChange: Bool, actions: [ExamAction]) {
        self.summary = summary
        self.expectsVisualChange = expectsVisualChange
        self.actions = actions
    }
}

public struct ValidatedBatch: Equatable {
    public let summary: String
    public let expectsVisualChange: Bool
    public let actions: [ExamAction]
    public let stateVersion: UInt64
    public let deferredProtectedBoundary: Bool
    public let expectedOutcome: ExpectedOutcomeKind

    public init(
        summary: String,
        expectsVisualChange: Bool,
        actions: [ExamAction],
        stateVersion: UInt64 = 0,
        deferredProtectedBoundary: Bool = false,
        expectedOutcome: ExpectedOutcomeKind = .none
    ) {
        self.summary = summary
        self.expectsVisualChange = expectsVisualChange
        self.actions = actions
        self.stateVersion = stateVersion
        self.deferredProtectedBoundary = deferredProtectedBoundary
        self.expectedOutcome = expectedOutcome
    }

    public var containsProtectedBoundary: Bool {
        actions.contains { $0.boundary && $0.kind != .finish }
    }

    public var hasPotentialAnswerMutation: Bool {
        actions.contains { action in
            switch action.kind {
            case .moveClick, .typeText, .key:
                return !action.boundary
            case .scroll, .wait, .finish:
                return false
            }
        }
    }
}

public enum ActionValidationError: Error, Equatable, LocalizedError {
    case tooManyActions
    case coordinateOutOfBounds
    case waitOutOfRange
    case scrollOutOfRange
    case unsupportedKey(String)
    case missingRequiredField(ExamActionKind)
    case protectedBoundaryBeforeAnswer

    public var errorDescription: String? {
        switch self {
        case .tooManyActions:
            return "A decision may contain at most 12 actions."
        case .coordinateOutOfBounds:
            return "Mouse coordinates are outside the captured screen bounds."
        case .waitOutOfRange:
            return "Wait duration must be between 0 and 5000 milliseconds."
        case .scrollOutOfRange:
            return "Scroll amount must be between -1400 and 1400 pixels."
        case .unsupportedKey(let key):
            return "Unsupported key action: \(key)."
        case .missingRequiredField(let kind):
            return "Action \(kind.rawValue) is missing a required field."
        case .protectedBoundaryBeforeAnswer:
            return "A protected boundary cannot execute before the current question has a verified answer."
        }
    }
}

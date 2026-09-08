import Foundation
import CoreGraphics

public struct ScreenFrame {
    public let image: CGImage
    public let jpegData: Data
    public let screenBounds: CGRect

    public init(image: CGImage, jpegData: Data, screenBounds: CGRect) {
        self.image = image
        self.jpegData = jpegData
        self.screenBounds = screenBounds
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

    public init(summary: String, expectsVisualChange: Bool, actions: [ExamAction]) {
        self.summary = summary
        self.expectsVisualChange = expectsVisualChange
        self.actions = actions
    }
}

public enum ActionValidationError: Error, Equatable, LocalizedError {
    case tooManyActions
    case coordinateOutOfBounds
    case waitOutOfRange
    case scrollOutOfRange
    case missingRequiredField(ExamActionKind)

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
        case .missingRequiredField(let kind):
            return "Action \(kind.rawValue) is missing a required field."
        }
    }
}

import Foundation
import CoreGraphics

public enum BrowserSemanticRole: String, Codable, CaseIterable, Equatable {
    case button
    case checkBox = "check_box"
    case radioButton = "radio_button"
    case textField = "text_field"
    case link
    case comboBox = "combo_box"
    case listBox = "list_box"
    case option
    case menuItem = "menu_item"
    case tab
    case switchControl = "switch"
}

public struct BrowserSemanticWindowBounds: Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height)
        )
    }

    fileprivate func approximatelyEquals(
        _ other: BrowserSemanticWindowBounds,
        tolerance: Double
    ) -> Bool {
        abs(x - other.x) <= tolerance
            && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

public struct BrowserSemanticNormalizedBounds: Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    fileprivate func clamped() -> BrowserSemanticNormalizedBounds {
        BrowserSemanticNormalizedBounds(
            x: Self.unit(x),
            y: Self.unit(y),
            width: Self.unit(width),
            height: Self.unit(height)
        )
    }

    fileprivate var isMeaningful: Bool {
        width > 0 && height > 0
    }

    private static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

public struct BrowserSemanticElementHint: Codable, Equatable {
    public let role: BrowserSemanticRole
    public let bounds: BrowserSemanticNormalizedBounds
    public let isFocused: Bool
    public let isSelected: Bool?
    public let isEnabled: Bool

    public init(
        role: BrowserSemanticRole,
        bounds: BrowserSemanticNormalizedBounds,
        isFocused: Bool,
        isSelected: Bool?,
        isEnabled: Bool
    ) {
        self.role = role
        self.bounds = bounds
        self.isFocused = isFocused
        self.isSelected = isSelected
        self.isEnabled = isEnabled
    }

    fileprivate func normalized() -> BrowserSemanticElementHint? {
        let safeBounds = bounds.clamped()
        guard safeBounds.isMeaningful else { return nil }
        return BrowserSemanticElementHint(
            role: role,
            bounds: safeBounds,
            isFocused: isFocused,
            isSelected: isSelected,
            isEnabled: isEnabled
        )
    }
}

public struct BrowserSemanticSnapshot: Codable, Equatable {
    public let stateVersion: UInt64
    public let processID: Int32
    public let windowBounds: BrowserSemanticWindowBounds
    public let viewportWidth: Double
    public let viewportHeight: Double
    public let elements: [BrowserSemanticElementHint]

    public init(
        stateVersion: UInt64,
        processID: Int32,
        windowBounds: BrowserSemanticWindowBounds,
        viewportWidth: Double,
        viewportHeight: Double,
        elements: [BrowserSemanticElementHint]
    ) {
        self.stateVersion = stateVersion
        self.processID = processID
        self.windowBounds = windowBounds
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.elements = elements
    }
}

public struct BrowserSemanticObservation: Codable, Equatable {
    public let stateVersion: UInt64
    public let processID: Int32
    public let windowBounds: BrowserSemanticWindowBounds
    public let viewportWidth: Double
    public let viewportHeight: Double
    public let elements: [BrowserSemanticElementHint]

    public init(
        stateVersion: UInt64,
        processID: Int32,
        windowBounds: BrowserSemanticWindowBounds,
        viewportWidth: Double,
        viewportHeight: Double,
        elements: [BrowserSemanticElementHint]
    ) {
        self.stateVersion = stateVersion
        self.processID = processID
        self.windowBounds = windowBounds
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.elements = elements
    }

    public func plannerHintSummary(maxElements: Int = 24) -> String {
        let limit = max(1, min(maxElements, 48))
        let hints = elements.prefix(limit).map { element in
            let selected = element.isSelected.map(String.init) ?? "unknown"
            let bounds = element.bounds
            return String(
                format: "%@[nx=%.3f,ny=%.3f,nw=%.3f,nh=%.3f,focused=%@,selected=%@,enabled=%@]",
                element.role.rawValue,
                bounds.x,
                bounds.y,
                bounds.width,
                bounds.height,
                String(element.isFocused),
                selected,
                String(element.isEnabled)
            )
        }
        return hints.isEmpty ? "none" : hints.joined(separator: ";")
    }
}

public protocol BrowserSemanticObserving: AnyObject {
    func observe(
        target: ScreenFrame,
        stateVersion: UInt64
    ) async throws -> BrowserSemanticSnapshot?
}

public struct BrowserSemanticObservationFusion {
    private let windowTolerance: Double
    private let maximumElementCount: Int

    public init(
        windowTolerance: Double = 8,
        maximumElementCount: Int = 48
    ) {
        self.windowTolerance = max(0, windowTolerance)
        self.maximumElementCount = max(1, min(maximumElementCount, 96))
    }

    public func fuse(
        snapshot: BrowserSemanticSnapshot?,
        target: ScreenFrame,
        stateVersion: UInt64
    ) -> BrowserSemanticObservation? {
        guard let snapshot,
              let targetProcessID = target.targetProcessID,
              snapshot.stateVersion == stateVersion,
              snapshot.processID == targetProcessID,
              snapshot.viewportWidth.isFinite,
              snapshot.viewportHeight.isFinite,
              snapshot.viewportWidth > 0,
              snapshot.viewportHeight > 0 else {
            return nil
        }

        let targetBounds = BrowserSemanticWindowBounds(target.screenBounds)
        guard snapshot.windowBounds.approximatelyEquals(
            targetBounds,
            tolerance: windowTolerance
        ) else {
            return nil
        }

        let safeElements = Array(
            snapshot.elements
                .compactMap { $0.normalized() }
                .prefix(maximumElementCount)
        )

        return BrowserSemanticObservation(
            stateVersion: stateVersion,
            processID: targetProcessID,
            windowBounds: snapshot.windowBounds,
            viewportWidth: snapshot.viewportWidth,
            viewportHeight: snapshot.viewportHeight,
            elements: safeElements
        )
    }
}

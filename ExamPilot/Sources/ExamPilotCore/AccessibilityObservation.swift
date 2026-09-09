import Foundation
import ApplicationServices
import CoreGraphics

public enum AccessibilityObservationError: Error, Equatable, LocalizedError {
    case notTrusted
    case missingTargetProcess
    case focusedWindowUnavailable

    public var errorDescription: String? {
        switch self {
        case .notTrusted:
            return "Accessibility permission is not available."
        case .missingTargetProcess:
            return "The captured frame has no target process identity."
        case .focusedWindowUnavailable:
            return "The focused Accessibility window could not be observed."
        }
    }
}

public enum AccessibilityRole: String, Codable, Equatable {
    case button
    case checkBox = "check_box"
    case radioButton = "radio_button"
    case textField = "text_field"
    case textArea = "text_area"
    case link
    case menuItem = "menu_item"
    case other
}

public struct AccessibilityBounds: Codable, Equatable {
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

    public var cgRect: CGRect {
        CGRect(
            x: CGFloat(x),
            y: CGFloat(y),
            width: CGFloat(width),
            height: CGFloat(height)
        )
    }

    fileprivate func approximatelyEquals(_ other: AccessibilityBounds, tolerance: Double) -> Bool {
        abs(x - other.x) <= tolerance
            && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }

    fileprivate func intersects(_ other: AccessibilityBounds) -> Bool {
        let intersection = cgRect.intersection(other.cgRect)
        return !intersection.isNull && !intersection.isEmpty
    }
}

public struct AccessibilityElementHint: Codable, Equatable {
    public let role: AccessibilityRole
    public let bounds: AccessibilityBounds
    public let isFocused: Bool
    public let isSelected: Bool?
    public let isEnabled: Bool

    public init(
        role: AccessibilityRole,
        bounds: AccessibilityBounds,
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
}

public struct AccessibilitySnapshot: Codable, Equatable {
    public let stateVersion: UInt64
    public let processID: Int32
    public let windowBounds: AccessibilityBounds
    public let elements: [AccessibilityElementHint]

    public init(
        stateVersion: UInt64,
        processID: Int32,
        windowBounds: AccessibilityBounds,
        elements: [AccessibilityElementHint]
    ) {
        self.stateVersion = stateVersion
        self.processID = processID
        self.windowBounds = windowBounds
        self.elements = elements
    }
}

public struct AccessibilityObservation: Codable, Equatable {
    public let stateVersion: UInt64
    public let processID: Int32
    public let windowBounds: AccessibilityBounds
    public let elements: [AccessibilityElementHint]

    public init(
        stateVersion: UInt64,
        processID: Int32,
        windowBounds: AccessibilityBounds,
        elements: [AccessibilityElementHint]
    ) {
        self.stateVersion = stateVersion
        self.processID = processID
        self.windowBounds = windowBounds
        self.elements = elements
    }

    public var selectedElementCount: Int {
        elements.reduce(into: 0) { count, element in
            if element.isSelected == true {
                count += 1
            }
        }
    }

    public func plannerHintSummary(maxElements: Int = 24) -> String {
        let limit = max(1, min(maxElements, 64))
        let hints = elements.prefix(limit).map { element in
            let selected = element.isSelected.map(String.init) ?? "unknown"
            let bounds = element.bounds
            return "\(element.role.rawValue)[x=\(Int(bounds.x.rounded())),y=\(Int(bounds.y.rounded())),w=\(Int(bounds.width.rounded())),h=\(Int(bounds.height.rounded())),focused=\(element.isFocused),selected=\(selected),enabled=\(element.isEnabled)]"
        }
        return hints.isEmpty ? "none" : hints.joined(separator: ";")
    }
}

public protocol AccessibilityObserving: AnyObject {
    func observe(target: ScreenFrame, stateVersion: UInt64) throws -> AccessibilitySnapshot?
}

public struct AccessibilityObservationFusion {
    private let windowTolerance: Double
    private let maximumElementCount: Int

    public init(windowTolerance: Double = 4, maximumElementCount: Int = 64) {
        self.windowTolerance = max(0, windowTolerance)
        self.maximumElementCount = max(1, min(maximumElementCount, 128))
    }

    public func fuse(
        snapshot: AccessibilitySnapshot?,
        target: ScreenFrame,
        stateVersion: UInt64
    ) -> AccessibilityObservation? {
        guard let snapshot,
              let targetProcessID = target.targetProcessID,
              snapshot.stateVersion == stateVersion,
              snapshot.processID == targetProcessID else {
            return nil
        }

        let targetBounds = AccessibilityBounds(target.screenBounds)
        guard snapshot.windowBounds.approximatelyEquals(
            targetBounds,
            tolerance: windowTolerance
        ) else {
            return nil
        }

        let boundedElements = Array(
            snapshot.elements
                .filter { $0.bounds.intersects(targetBounds) }
                .prefix(maximumElementCount)
        )

        return AccessibilityObservation(
            stateVersion: stateVersion,
            processID: targetProcessID,
            windowBounds: snapshot.windowBounds,
            elements: boundedElements
        )
    }
}

public final class MacOSAccessibilityObserver: AccessibilityObserving {
    private let maximumElementCount: Int
    private let maximumDepth: Int
    private let maximumVisitedElementCount: Int

    public init(maximumElementCount: Int = 64, maximumDepth: Int = 8) {
        let elementLimit = max(1, min(maximumElementCount, 128))
        self.maximumElementCount = elementLimit
        self.maximumDepth = max(1, min(maximumDepth, 12))
        self.maximumVisitedElementCount = elementLimit * 8
    }

    public func observe(target: ScreenFrame, stateVersion: UInt64) throws -> AccessibilitySnapshot? {
        guard AXIsProcessTrusted() else {
            throw AccessibilityObservationError.notTrusted
        }
        guard let processID = target.targetProcessID else {
            throw AccessibilityObservationError.missingTargetProcess
        }

        let application = AXUIElementCreateApplication(processID)
        guard let focusedWindow = attribute(
            application,
            kAXFocusedWindowAttribute as CFString
        ) as! AXUIElement?,
              let windowFrame = frame(of: focusedWindow) else {
            throw AccessibilityObservationError.focusedWindowUnavailable
        }

        var result: [AccessibilityElementHint] = []
        var queue: [(element: AXUIElement, depth: Int)] = childElements(of: focusedWindow).map {
            ($0, 1)
        }
        var index = 0
        var visited = 0
        let targetBounds = AccessibilityBounds(target.screenBounds)

        while index < queue.count,
              visited < maximumVisitedElementCount,
              result.count < maximumElementCount {
            let item = queue[index]
            index += 1
            visited += 1

            if let hint = hint(for: item.element), hint.bounds.intersects(targetBounds) {
                result.append(hint)
            }

            if item.depth < maximumDepth {
                let children = childElements(of: item.element)
                let remainingVisitBudget = maximumVisitedElementCount - queue.count
                if remainingVisitBudget > 0 {
                    queue.append(contentsOf: children.prefix(remainingVisitBudget).map {
                        ($0, item.depth + 1)
                    })
                }
            }
        }

        return AccessibilitySnapshot(
            stateVersion: stateVersion,
            processID: processID,
            windowBounds: AccessibilityBounds(windowFrame),
            elements: result
        )
    }

    private func hint(for element: AXUIElement) -> AccessibilityElementHint? {
        guard let bounds = frame(of: element) else { return nil }
        let role = accessibilityRole(
            from: attribute(element, kAXRoleAttribute as CFString) as? String
        )
        guard role != .other else { return nil }

        return AccessibilityElementHint(
            role: role,
            bounds: AccessibilityBounds(bounds),
            isFocused: booleanAttribute(element, kAXFocusedAttribute as CFString) ?? false,
            isSelected: booleanAttribute(element, kAXSelectedAttribute as CFString),
            isEnabled: booleanAttribute(element, kAXEnabledAttribute as CFString) ?? true
        )
    }

    private func accessibilityRole(from rawRole: String?) -> AccessibilityRole {
        switch rawRole {
        case "AXButton": return .button
        case "AXCheckBox": return .checkBox
        case "AXRadioButton": return .radioButton
        case "AXTextField": return .textField
        case "AXTextArea": return .textArea
        case "AXLink": return .link
        case "AXMenuItem": return .menuItem
        default: return .other
        }
    }

    private func childElements(of element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
    }

    private func booleanAttribute(_ element: AXUIElement, _ name: CFString) -> Bool? {
        attribute(element, name) as? Bool
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(
            element,
            kAXPositionAttribute as CFString
        ) as! AXValue?,
              let sizeValue = attribute(
                element,
                kAXSizeAttribute as CFString
              ) as! AXValue?,
              AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name, &value)
        return error == .success ? value : nil
    }
}

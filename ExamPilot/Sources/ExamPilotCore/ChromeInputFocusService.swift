import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

public enum ChromeInputFocusError: Error, LocalizedError, Equatable {
    case missingProcessID
    case targetProcessUnavailable
    case activationFailed
    case accessibilityUnavailable
    case focusedWindowUnavailable
    case focusedWindowMismatch

    public var errorDescription: String? {
        switch self {
        case .missingProcessID:
            return "The captured Chrome frame has no target process identifier."
        case .targetProcessUnavailable:
            return "The captured Chrome process is no longer running."
        case .activationFailed:
            return "Google Chrome could not be activated before physical input."
        case .accessibilityUnavailable:
            return "Accessibility access is required to verify the captured Chrome window before physical input."
        case .focusedWindowUnavailable:
            return "The focused Chrome window could not be resolved before physical input."
        case .focusedWindowMismatch:
            return "Chrome focus moved to a different window after the screenshot; physical input was cancelled."
        }
    }
}

struct ChromeInputFocusPolicy {
    let minimumIntersectionOverUnion: CGFloat

    init(minimumIntersectionOverUnion: CGFloat = 0.65) {
        self.minimumIntersectionOverUnion = minimumIntersectionOverUnion
    }

    func matchesCapturedWindow(captured: CGRect, focused: CGRect) -> Bool {
        guard !captured.isNull,
              !captured.isEmpty,
              !focused.isNull,
              !focused.isEmpty else {
            return false
        }

        let intersection = captured.intersection(focused)
        guard !intersection.isNull, !intersection.isEmpty else { return false }

        let intersectionArea = area(intersection)
        let unionArea = area(captured) + area(focused) - intersectionArea
        guard unionArea > 0 else { return false }

        return intersectionArea / unionArea >= minimumIntersectionOverUnion
    }

    private func area(_ rect: CGRect) -> CGFloat {
        max(0, rect.width) * max(0, rect.height)
    }
}

public struct ChromeInputFocusService {
    private let policy = ChromeInputFocusPolicy()

    public init() {}

    public func focus(frame: ScreenFrame) async throws {
        guard let rawPID = frame.targetProcessID else {
            throw ChromeInputFocusError.missingProcessID
        }
        let pid = pid_t(rawPID)
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            throw ChromeInputFocusError.targetProcessUnavailable
        }
        guard app.activate(options: [.activateAllWindows]) else {
            throw ChromeInputFocusError.activationFailed
        }
        guard AXIsProcessTrusted() else {
            throw ChromeInputFocusError.accessibilityUnavailable
        }

        // Global CGEvents are intentionally not posted until the exact Chrome window
        // represented by the screenshot is still the focused window. A user switching
        // to another Chrome window during model reasoning therefore fails closed instead
        // of typing or clicking into stale coordinates.
        let axApp = AXUIElementCreateApplication(pid)
        guard let focusedWindow = attribute(axApp, kAXFocusedWindowAttribute as CFString) as! AXUIElement? else {
            throw ChromeInputFocusError.focusedWindowUnavailable
        }

        _ = AXUIElementPerformAction(focusedWindow, kAXRaiseAction as CFString)
        try await Task.sleep(nanoseconds: 140_000_000)

        guard let verifiedWindow = attribute(axApp, kAXFocusedWindowAttribute as CFString) as! AXUIElement?,
              let focusedFrame = windowFrame(verifiedWindow),
              policy.matchesCapturedWindow(captured: frame.screenBounds, focused: focusedFrame) else {
            throw ChromeInputFocusError.focusedWindowMismatch
        }
    }

    private func windowFrame(_ window: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(window, kAXPositionAttribute as CFString) as! AXValue?,
              let sizeValue = attribute(window, kAXSizeAttribute as CFString) as! AXValue?,
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

    private func attribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        return error == .success ? value : nil
    }
}

import Foundation
import AppKit
import ApplicationServices

public enum ChromeInputFocusError: Error, LocalizedError, Equatable {
    case missingProcessID
    case targetProcessUnavailable
    case activationFailed

    public var errorDescription: String? {
        switch self {
        case .missingProcessID:
            return "The captured Chrome frame has no target process identifier."
        case .targetProcessUnavailable:
            return "The captured Chrome process is no longer running."
        case .activationFailed:
            return "Google Chrome could not be activated before physical input."
        }
    }
}

public struct ChromeInputFocusService {
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

        if AXIsProcessTrusted() {
            let axApp = AXUIElementCreateApplication(pid)
            if let focusedWindow = attribute(axApp, kAXFocusedWindowAttribute as CFString) as! AXUIElement? {
                _ = AXUIElementPerformAction(focusedWindow, kAXRaiseAction as CFString)
            }
        }

        try await Task.sleep(nanoseconds: 140_000_000)
    }

    private func attribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        return error == .success ? value : nil
    }
}

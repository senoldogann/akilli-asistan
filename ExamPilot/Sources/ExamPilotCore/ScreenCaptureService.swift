import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

public protocol ScreenCapturing {
    func capture() async throws -> ScreenFrame
}

public enum ScreenCaptureError: Error, LocalizedError, Equatable {
    case chromeWindowNotFound
    case jpegEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .chromeWindowNotFound:
            return "No visible Google Chrome window was found. Open the authorized quiz/exam in Chrome and keep the window visible."
        case .jpegEncodingFailed:
            return "The captured Chrome window could not be encoded as JPEG."
        }
    }
}

public struct ScreenCaptureService: ScreenCapturing {
    private let selectionPolicy = ChromeWindowSelectionPolicy()

    public init() {}

    public func capture() async throws -> ScreenFrame {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = chromeWindow(in: content.windows) else {
            throw ScreenCaptureError.chromeWindowNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = backingScale(for: window.frame)
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        let jpeg = try encodeJPEG(image)
        return ScreenFrame(
            image: image,
            jpegData: jpeg,
            screenBounds: window.frame,
            targetProcessID: window.owningApplication?.processID
        )
    }

    private func chromeWindow(in windows: [SCWindow]) -> SCWindow? {
        let chromeWindows = windows.filter { window in
            guard let app = window.owningApplication else { return false }
            return isChrome(bundleIdentifier: app.bundleIdentifier, name: app.applicationName)
                && window.frame.width >= 320
                && window.frame.height >= 240
        }
        guard !chromeWindows.isEmpty else { return nil }

        let candidates = chromeWindows.compactMap { window -> ChromeWindowCandidate? in
            guard let app = window.owningApplication else { return nil }
            return ChromeWindowCandidate(
                windowID: window.windowID,
                processID: app.processID,
                frame: window.frame
            )
        }

        let focused = focusedChromeContext(candidates: candidates)
        guard let selected = selectionPolicy.select(
            candidates,
            focusedProcessID: focused?.processID,
            focusedFrame: focused?.frame
        ) else {
            return nil
        }

        return chromeWindows.first { $0.windowID == selected.windowID }
    }

    private func focusedChromeContext(
        candidates: [ChromeWindowCandidate]
    ) -> (processID: pid_t, frame: CGRect)? {
        guard AXIsProcessTrusted() else { return nil }

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           isChrome(
                bundleIdentifier: frontmost.bundleIdentifier ?? "",
                name: frontmost.localizedName ?? ""
           ),
           let frame = focusedWindowFrame(processID: frontmost.processIdentifier) {
            return (frontmost.processIdentifier, frame)
        }

        let processIDs = Set(candidates.map(\.processID)).sorted()
        for processID in processIDs {
            if let frame = focusedWindowFrame(processID: processID) {
                return (processID, frame)
            }
        }
        return nil
    }

    private func focusedWindowFrame(processID: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(processID)
        guard let window = attribute(app, kAXFocusedWindowAttribute as CFString) as! AXUIElement?,
              let positionValue = attribute(window, kAXPositionAttribute as CFString) as! AXValue?,
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

    private func isChrome(bundleIdentifier: String, name: String) -> Bool {
        let bundle = bundleIdentifier.lowercased()
        let appName = name.lowercased()
        return bundle.contains("google.chrome") || appName.contains("google chrome")
    }

    private func backingScale(for frame: CGRect) -> CGFloat {
        let candidate = NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(frame).width * lhs.frame.intersection(frame).height
                < rhs.frame.intersection(frame).width * rhs.frame.intersection(frame).height
        }
        return candidate?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func encodeJPEG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenCaptureError.jpegEncodingFailed
        }

        let options: CFDictionary = [
            kCGImageDestinationLossyCompressionQuality: 0.82
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenCaptureError.jpegEncodingFailed
        }
        return data as Data
    }
}

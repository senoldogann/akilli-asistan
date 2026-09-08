import Foundation
import AppKit
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
        return ScreenFrame(image: image, jpegData: jpeg, screenBounds: window.frame)
    }

    private func chromeWindow(in windows: [SCWindow]) -> SCWindow? {
        windows
            .filter { window in
                guard let app = window.owningApplication else { return false }
                let bundle = app.bundleIdentifier.lowercased()
                let name = app.applicationName.lowercased()
                return (bundle.contains("google.chrome") || name.contains("google chrome"))
                    && window.frame.width >= 320
                    && window.frame.height >= 240
            }
            .max { lhs, rhs in
                lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
            }
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

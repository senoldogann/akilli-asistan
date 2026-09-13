import ApplicationServices
import ComputerAgentMacOS
import CoreGraphics
import Foundation

/// Live, read-only macOS observation source used by `MacOSComputerObservationProvider`.
///
/// This lives outside the runtime composition root so `ZeroLoseRuntimeContainer` stays a
/// pure wiring surface (see `UIBoundaryTests.testRuntimeContainerIsCompositionRootNotAUIExecutionBackdoor`).
/// It observes only; it never drives input.
enum LiveMacOSComputerObservationSourceError: Error {
    case unavailable
}

struct LiveMacOSComputerObservationSourceProvider: MacOSComputerObservationSourceProviding {
    private struct WindowCandidate {
        let processID: Int32
        let windowID: UInt32
        let frame: CGRect
    }

    private struct ObservationSnapshot {
        let screen: WindowCandidate
        let accessibility: WindowCandidate
    }

    static func makeIfReady() -> LiveMacOSComputerObservationSourceProvider? {
        guard CGPreflightScreenCaptureAccess(),
              AXIsProcessTrusted(),
              let snapshot = try? currentSnapshot(),
              snapshot.screen.processID == snapshot.accessibility.processID,
              snapshot.screen.windowID == snapshot.accessibility.windowID else {
            return nil
        }
        return LiveMacOSComputerObservationSourceProvider()
    }

    func currentObservationSources() async throws -> MacOSComputerObservationSources {
        guard CGPreflightScreenCaptureAccess(), AXIsProcessTrusted() else {
            throw LiveMacOSComputerObservationSourceError.unavailable
        }

        let snapshot = try Self.currentSnapshot()
        return MacOSComputerObservationSources(
            screen: ComputerObservationSource(
                processID: snapshot.screen.processID,
                windowID: snapshot.screen.windowID,
                provenance: "macos:screen-window",
                tainted: false,
                confidence: 1.0
            ),
            accessibility: ComputerObservationSource(
                processID: snapshot.accessibility.processID,
                windowID: snapshot.accessibility.windowID,
                provenance: "macos:accessibility-focus",
                tainted: false,
                confidence: 1.0
            )
        )
    }

    private static func currentSnapshot() throws -> ObservationSnapshot {
        let candidates = windowCandidates()
        guard let screen = candidates.first,
              let accessibilityContext = focusedAccessibilityContext(),
              let accessibility = candidates.first(where: {
                  $0.processID == accessibilityContext.processID
                      && framesMatch($0.frame, accessibilityContext.frame)
              }) else {
            throw LiveMacOSComputerObservationSourceError.unavailable
        }

        return ObservationSnapshot(
            screen: screen,
            accessibility: accessibility
        )
    }

    private static func windowCandidates() -> [WindowCandidate] {
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return rawWindows.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? NSNumber,
                  let y = bounds["Y"] as? NSNumber,
                  let width = bounds["Width"] as? NSNumber,
                  let height = bounds["Height"] as? NSNumber,
                  width.doubleValue > 1,
                  height.doubleValue > 1 else {
                return nil
            }

            let frame = CGRect(
                x: x.doubleValue,
                y: y.doubleValue,
                width: width.doubleValue,
                height: height.doubleValue
            )

            return WindowCandidate(
                processID: ownerPID.int32Value,
                windowID: windowNumber.uint32Value,
                frame: frame
            )
        }
    }

    private static func focusedAccessibilityContext() -> (processID: Int32, frame: CGRect)? {
        let systemWide = AXUIElementCreateSystemWide()
        guard let application = attribute(
            systemWide,
            kAXFocusedApplicationAttribute as CFString
        ) as! AXUIElement? else {
            return nil
        }

        var processID: pid_t = 0
        guard AXUIElementGetPid(application, &processID) == .success,
              let focusedWindow = attribute(
                  application,
                  kAXFocusedWindowAttribute as CFString
              ) as! AXUIElement?,
              let frame = frame(of: focusedWindow) else {
            return nil
        }

        return (Int32(processID), frame)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
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
              size.width > 1,
              size.height > 1 else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    private static func attribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name, &value)
        return error == .success ? value : nil
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 2
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}

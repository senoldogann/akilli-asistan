import Foundation
import CoreGraphics

public protocol InputDriving: AnyObject {
    func moveAndClick(x: Double, y: Double) async throws
    func typeText(_ text: String) async throws
    func pressKey(_ key: String) async throws
    func scroll(amount: Int) async throws
    func wait(milliseconds: Int) async throws
}

public struct HumanInputProfile: Equatable {
    public let keyDelayRangeMilliseconds: ClosedRange<Int>
    public let mouseDurationRangeMilliseconds: ClosedRange<Int>

    public init(
        keyDelayRangeMilliseconds: ClosedRange<Int> = 35...90,
        mouseDurationRangeMilliseconds: ClosedRange<Int> = 160...420
    ) {
        self.keyDelayRangeMilliseconds = keyDelayRangeMilliseconds
        self.mouseDurationRangeMilliseconds = mouseDurationRangeMilliseconds
    }

    public func keyDelayMilliseconds(randomUnit: Double) -> Int {
        interpolate(range: keyDelayRangeMilliseconds, randomUnit: randomUnit)
    }

    public func mouseDurationMilliseconds(randomUnit: Double) -> Int {
        interpolate(range: mouseDurationRangeMilliseconds, randomUnit: randomUnit)
    }

    private func interpolate(range: ClosedRange<Int>, randomUnit: Double) -> Int {
        let unit = max(0, min(1, randomUnit))
        let span = Double(range.upperBound - range.lowerBound)
        return range.lowerBound + Int((span * unit).rounded())
    }
}

public enum InputDriverError: Error, LocalizedError, Equatable {
    case eventSourceUnavailable
    case eventCreationFailed
    case unsupportedKey(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .eventSourceUnavailable:
            return "CoreGraphics could not create an HID event source."
        case .eventCreationFailed:
            return "CoreGraphics could not create an input event."
        case .unsupportedKey(let key):
            return "Unsupported key: \(key)"
        case .cancelled:
            return "Physical input was cancelled by the emergency stop request."
        }
    }
}

public final class NativeInputDriver: InputDriving {
    private let profile: HumanInputProfile
    private let randomUnit: () -> Double
    private let shouldStop: () -> Bool

    public init(
        profile: HumanInputProfile = HumanInputProfile(),
        randomUnit: @escaping () -> Double = { Double.random(in: 0...1) },
        shouldStop: @escaping () -> Bool = { false }
    ) {
        self.profile = profile
        self.randomUnit = randomUnit
        self.shouldStop = shouldStop
    }

    public func moveAndClick(x: Double, y: Double) async throws {
        try checkStop()
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw InputDriverError.eventSourceUnavailable
        }

        let start = CGEvent(source: nil)?.location ?? CGPoint(x: x, y: y)
        let end = CGPoint(x: x, y: y)
        let duration = profile.mouseDurationMilliseconds(randomUnit: randomUnit())
        let distance = hypot(end.x - start.x, end.y - start.y)
        let steps = max(12, min(64, Int(distance / 18) + 12))

        let dx = end.x - start.x
        let dy = end.y - start.y
        let perpendicular = CGVector(dx: -dy, dy: dx)
        let magnitude = max(1, hypot(perpendicular.dx, perpendicular.dy))
        let bend = min(70, max(8, distance * 0.08)) * (randomUnit() - 0.5)
        let offset = CGVector(
            dx: perpendicular.dx / magnitude * bend,
            dy: perpendicular.dy / magnitude * bend
        )
        let c1 = CGPoint(x: start.x + dx * 0.30 + offset.dx, y: start.y + dy * 0.30 + offset.dy)
        let c2 = CGPoint(x: start.x + dx * 0.72 - offset.dx, y: start.y + dy * 0.72 - offset.dy)

        let stepNanos = UInt64(max(1, duration / steps)) * 1_000_000
        for index in 1...steps {
            try checkStop()
            let t = CGFloat(index) / CGFloat(steps)
            let point = cubicBezier(start, c1, c2, end, t)
            guard let move = CGEvent(
                mouseEventSource: source,
                mouseType: .mouseMoved,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else {
                throw InputDriverError.eventCreationFailed
            }
            move.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: stepNanos)
        }

        try checkStop()
        guard let down = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: end,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: end,
            mouseButton: .left
        ) else {
            throw InputDriverError.eventCreationFailed
        }

        down.post(tap: .cghidEventTap)
        // Once mouseDown is posted, always post mouseUp even if stop is requested
        // during this short interval so the system is never left with a stuck button.
        try await Task.sleep(nanoseconds: UInt64(45 + Int(randomUnit() * 45)) * 1_000_000)
        up.post(tap: .cghidEventTap)
    }

    public func typeText(_ text: String) async throws {
        guard !text.isEmpty else { return }

        for character in text {
            try checkStop()
            if character == "\n" {
                try await pressKey("return")
            } else if character == "\t" {
                try await pressKey("tab")
            } else {
                try postUnicode(String(character))
            }

            let baseDelay = profile.keyDelayMilliseconds(randomUnit: randomUnit())
            let punctuationPause: Int
            if character == "\n" {
                punctuationPause = 70
            } else if ".,;:{}()[]".contains(character) {
                punctuationPause = 20
            } else {
                punctuationPause = 0
            }
            try await Task.sleep(nanoseconds: UInt64(baseDelay + punctuationPause) * 1_000_000)
        }
    }

    public func pressKey(_ key: String) async throws {
        try checkStop()
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw InputDriverError.eventSourceUnavailable
        }
        guard let keyCode = Self.keyCode(for: key) else {
            throw InputDriverError.unsupportedKey(key)
        }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw InputDriverError.eventCreationFailed
        }
        down.post(tap: .cghidEventTap)
        // Keep key-up paired with key-down even if stop arrives during the press.
        try await Task.sleep(nanoseconds: 28_000_000)
        up.post(tap: .cghidEventTap)
    }

    public func scroll(amount: Int) async throws {
        try checkStop()
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw InputDriverError.eventSourceUnavailable
        }
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(amount),
            wheel2: 0,
            wheel3: 0
        ) else {
            throw InputDriverError.eventCreationFailed
        }
        event.location = CGEvent(source: nil)?.location ?? .zero
        event.post(tap: .cghidEventTap)
    }

    public func wait(milliseconds: Int) async throws {
        guard milliseconds > 0 else { return }
        var remaining = milliseconds
        while remaining > 0 {
            try checkStop()
            let slice = min(50, remaining)
            try await Task.sleep(nanoseconds: UInt64(slice) * 1_000_000)
            remaining -= slice
        }
    }

    private func checkStop() throws {
        if shouldStop() {
            throw InputDriverError.cancelled
        }
    }

    private func postUnicode(_ text: String) throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw InputDriverError.eventCreationFailed
        }

        var units = Array(text.utf16)
        guard !units.isEmpty else { return }
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func keyCode(for key: String) -> CGKeyCode? {
        switch key.lowercased() {
        case "return", "enter": return 36
        case "tab": return 48
        case "space": return 49
        case "delete", "backspace": return 51
        case "escape", "esc": return 53
        case "home": return 115
        case "pageup", "page_up": return 116
        case "end": return 119
        case "pagedown", "page_down": return 121
        case "left", "arrowleft", "arrow_left": return 123
        case "right", "arrowright", "arrow_right": return 124
        case "down", "arrowdown", "arrow_down": return 125
        case "up", "arrowup", "arrow_up": return 126
        default: return nil
        }
    }

    private func cubicBezier(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let tt = t * t
        let uu = u * u
        let uuu = uu * u
        let ttt = tt * t
        return CGPoint(
            x: uuu * p0.x + 3 * uu * t * p1.x + 3 * u * tt * p2.x + ttt * p3.x,
            y: uuu * p0.y + 3 * uu * t * p1.y + 3 * u * tt * p2.y + ttt * p3.y
        )
    }
}

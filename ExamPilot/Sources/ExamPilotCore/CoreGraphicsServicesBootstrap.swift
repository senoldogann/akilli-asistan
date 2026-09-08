import CoreGraphics

enum CoreGraphicsServicesBootstrap {
    @MainActor
    @discardableResult
    static func initialize() -> CGDirectDisplayID {
        // ScreenCaptureKit's desktop-independent window filter can abort in
        // command-line processes if CoreGraphics Services has not been touched
        // yet. Initializing the main display on MainActor establishes the CGS
        // connection before any window filter is constructed.
        CGMainDisplayID()
    }
}

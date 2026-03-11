import Cocoa
import ScreenCaptureKit
import os

class VisionService {
    private let logger = Logger.vision
    
    // Captures the screen area using modern ScreenCaptureKit
    func captureScreen(under window: NSWindow) async -> NSImage? {
        do {
            // 1. Get Available Content
            let content = try await SCShareableContent.current
            
            // 2. Identify Main Display
            guard let display = content.displays.first else {
                logger.error("No displays found.")
                return nil
            }
            
            // 3. Create Filter and EXCLUDE current application for complete stealth
            let bundleID = Bundle.main.bundleIdentifier ?? "com.zerolose"
            let excludedApps = content.applications.filter { $0.bundleIdentifier == bundleID }
            
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            
            // 4. Configure Capture
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.showsCursor = false
            
            // 5. Take Screenshot (macOS 14+ API)
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            
            logger.info("Screen captured successfully (Filtered: \(excludedApps.count) apps)")
            return NSImage(cgImage: cgImage, size: NSSize(width: display.width, height: display.height))
            
        } catch {
            logger.error("ScreenCaptureKit Failed: \(error.localizedDescription)")
            return nil
        }
    }
}

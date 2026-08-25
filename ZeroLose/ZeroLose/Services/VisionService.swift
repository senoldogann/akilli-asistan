import Cocoa
import ScreenCaptureKit
import CoreGraphics
import os

class VisionService {
    private let logger = Logger.vision
    
    // Modern ScreenCaptureKit kullanarak ekran alanını yakalar.
    func captureScreen(under window: NSWindow) async -> NSImage? {
        do {
            guard CGPreflightScreenCaptureAccess() else {
                logger.error("Screen Recording permission is missing. Open System Settings > Privacy & Security > Screen Recording and enable ZeroLose.")
                return nil
            }

            // 1. Kullanılabilir İçeriği Al
            let content = try await SCShareableContent.current
            
            // 2. Ana Ekranı Tanımla
            guard let display = content.displays.first else {
                logger.error("No displays found.")
                return nil
            }
            
            // 3. Filtre Oluştur ve tam gizlilik için mevcut uygulamayı DIŞARIDA BIRAK
            let bundleID = Bundle.main.bundleIdentifier ?? "com.zerolose"
            let excludedApps = content.applications.filter { $0.bundleIdentifier == bundleID }
            
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            
            // 4. Yakalamayı Yapılandır
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.showsCursor = false
            
            // 5. Ekran Görüntüsü Al (macOS 14+ API)
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            
            logger.info("Screen captured successfully (Filtered: \(excludedApps.count) apps)")
            return NSImage(cgImage: cgImage, size: NSSize(width: display.width, height: display.height))
            
        } catch {
            logger.error("ScreenCaptureKit Failed: \(error.localizedDescription)")
            return nil
        }
    }
}

import Foundation
import Combine
import Cocoa
import os

/// Monitors the filesystem for new screenshots taken by macOS.
/// Uses FSEventStreamRef for reliable, real-time file system monitoring.
@MainActor
class ScreenshotWatcherService: ObservableObject {
    @Published var lastScreenshotData: Data?
    
    private var lastProcessedPath: String?
    private var eventStream: FSEventStreamRef?
    private let screenshotFolder: String
    private let processingQueue = DispatchQueue(label: "com.zerolose.screenshotwatcher", qos: .background)
    private let logger = Logger(subsystem: "com.zerolose", category: "screenshot-watcher")
    
    init() {
        // Default screenshot location: ~/Desktop
        self.screenshotFolder = NSHomeDirectory() + "/Desktop"
        startWatching()
    }
    
    private func startWatching() {
        let pathsToWatch = [screenshotFolder] as CFArray
        
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )
        
        eventStream = FSEventStreamCreate(
            nil,
            { (_, info, numEvents, eventPaths, eventFlags, _) in
                guard let info = info else { return }
                let watcher = Unmanaged<ScreenshotWatcherService>.fromOpaque(info).takeUnretainedValue()
                
                guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
                
                for i in 0..<numEvents {
                    let path = paths[i]
                    let flags = eventFlags[i]
                    
                    // Check if it's a new file creation (not a folder, not removal)
                    let isCreated = (flags & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
                    let isRenamed = (flags & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0
                    let isFile = (flags & UInt32(kFSEventStreamEventFlagItemIsFile)) != 0
                    let isRemoved = (flags & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0
                    
                    // Trigger on Creation OR Rename (Screenshots are often renamed from .EkranResmi to EkranResmi)
                    if (isCreated || isRenamed) && isFile && !isRemoved {
                        // Dispatch to main thread since this callback is on arbitrary thread
                        Task { @MainActor in
                            watcher.handleNewFile(at: path)
                        }
                    }
                }
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // Latency: 500ms to debounce rapid writes
            flags
        )
        
        if let stream = eventStream {
            FSEventStreamSetDispatchQueue(stream, processingQueue)
            FSEventStreamStart(stream)
            logger.info("Watching screenshot folder")
        }
    }
    
    private func stopWatching() {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }
    }
    
    private func handleNewFile(at path: String) {
        let filename = (path as NSString).lastPathComponent.lowercased()
        
        // Ignore hidden files (starting with dot)
        guard !filename.hasPrefix(".") else { return }
        
        // Check if filename matches screenshot pattern (Turkish: "Ekran Resmi", English: "Screen Shot")
        let isScreenshot = filename.contains("screen shot") ||
                           filename.contains("ekran resmi") ||
                           filename.hasPrefix("screenshot")
        
        guard isScreenshot else { return }
        
        // Check file extension
        let ext = (path as NSString).pathExtension.lowercased()
        guard ext == "png" || ext == "jpg" || ext == "jpeg" else { return }
        
        // Don't reprocess the same file
        guard path != lastProcessedPath else { return }
        
        logger.info("New screenshot detected")
        lastProcessedPath = path
        
        // Wait a bit for the file to be fully written
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000) // 800ms
            await loadScreenshot(from: path)
        }
    }
    
    private func loadScreenshot(from path: String) async {
        let url = URL(fileURLWithPath: path)
        
        do {
            let data = try Data(contentsOf: url)
            self.lastScreenshotData = data
            logger.info("Loaded screenshot bytes: \(data.count, privacy: .public)")
        } catch {
            logger.error("Failed to load screenshot: \(error.localizedDescription)")
        }
    }
}

import Foundation
import Combine
import Cocoa
import os

/// macOS tarafından alınan yeni ekran görüntüleri için dosya sistemini izler.
/// Güvenilir, gerçek zamanlı dosya sistemi izleme için FSEventStreamRef kullanır.
@MainActor
class ScreenshotWatcherService: ObservableObject {
    @Published var lastScreenshotData: Data?
    
    private var lastProcessedPath: String?
    private var eventStream: FSEventStreamRef?
    private let screenshotFolder: String
    private let processingQueue = DispatchQueue(label: "com.zerolose.screenshotwatcher", qos: .background)
    private let logger = Logger(subsystem: "com.zerolose", category: "screenshot-watcher")
    
    init() {
        // Varsayılan ekran görüntüsü konumu: ~/Desktop
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
                    
                    // Yeni dosya oluşturma mı (klasör değil, silinme değil) kontrol et
                    let isCreated = (flags & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
                    let isRenamed = (flags & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0
                    let isFile = (flags & UInt32(kFSEventStreamEventFlagItemIsFile)) != 0
                    let isRemoved = (flags & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0
                    
                    // Oluşturma VEYA Yeniden Adlandırma üzerinde tetikle (Ekran görüntüleri sık sık .EkranResmi'den EkranResmi'ye yeniden adlandırılır)
                    if (isCreated || isRenamed) && isFile && !isRemoved {
                        // Bu geri çağrı rastgele bir iş parçacığında olduğu için ana iş parçacığına gönder
                        Task { @MainActor in
                            watcher.handleNewFile(at: path)
                        }
                    }
                }
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // Gecikme: hızlı yazmaları birleştirmek için 500ms
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
        
        // Gizli dosyaları yok say (nokta ile başlayan)
        guard !filename.hasPrefix(".") else { return }
        
        // Dosya adı ekran görüntüsü kalıbıyla eşleşiyor mu kontrol et (Türkçe: "Ekran Resmi", İngilizce: "Screen Shot")
        let isScreenshot = filename.contains("screen shot") ||
                           filename.contains("ekran resmi") ||
                           filename.hasPrefix("screenshot")
        
        guard isScreenshot else { return }
        
        // Dosya uzantısını kontrol et
        let ext = (path as NSString).pathExtension.lowercased()
        guard ext == "png" || ext == "jpg" || ext == "jpeg" else { return }
        
        // Aynı dosyayı yeniden işleme
        guard path != lastProcessedPath else { return }
        
        logger.info("New screenshot detected")
        lastProcessedPath = path
        
        // Dosyanın tamamen yazılması için biraz bekle
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

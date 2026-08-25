import Cocoa
import Combine

class ClipboardService: ObservableObject {
    @Published var copiedText: String = ""
    
    private var timer: Timer?
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    
    init() {
        self.lastChangeCount = pasteboard.changeCount
        startMonitoring()
    }
    
    private func startMonitoring() {
        // Her 0.4 saniyede bir kontrol et (çift Cmd+C için yeterince hızlı)
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
    }
    
    private func checkForChanges() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        
        if let newString = pasteboard.string(forType: .string) {
            // Gerekirse boş dizeler veya devasa içeriklerde tetiklemeyi önle
            if !newString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DispatchQueue.main.async {
                    self.copiedText = newString
                }
            }
        }
    }
    
    deinit {
        timer?.invalidate()
    }
}

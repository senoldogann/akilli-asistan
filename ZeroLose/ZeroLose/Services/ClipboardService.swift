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
        // Poll every 0.4 seconds (Fast enough for double Cmd+C)
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
    }
    
    private func checkForChanges() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        
        if let newString = pasteboard.string(forType: .string) {
            // Avoid triggering on empty strings or huge blobs if needed
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

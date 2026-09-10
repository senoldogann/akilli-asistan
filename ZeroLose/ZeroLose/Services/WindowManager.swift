import Cocoa
import SwiftUI
import Observation
import os

// Kenarlıksız pencerelerin Key (Odaklanabilir) olmasına izin veren özel pencere sınıfı.
class GhostWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}

// Teleprompter için kenarlıksız pencere.
class TeleprompterWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}

// Ayarlar için özel pencere.
class SettingsWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}

@MainActor
class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()
    
    private enum WindowPreferenceKeys {
        static let teleprompterWidth = "teleprompterWindowWidth"
        static let teleprompterHeight = "teleprompterWindowHeight"
        static let teleprompterPosX = "teleprompterWindowPosX"
        static let teleprompterPosY = "teleprompterWindowPosY"
    }
    
    private var window: NSWindow!
    private var teleprompterWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var isClosingTeleprompterWindow = false
    private var isClosingSettingsWindow = false
    private let logger = Logger(subsystem: "com.zerolose", category: "WindowManager")
    private var stealthModeObserver: NSKeyValueObservation?
    
    private override init() {
        super.init()
    }
    
    func setupWindow() {
        let rect = NSRect(x: 100, y: 100, width: 450, height: 400)
        
        window = GhostWindow(
            contentRect: rect,
            styleMask: [.borderless, .fullSizeContentView, .resizable], 
            backing: .buffered,
            defer: false
        )
        
        window.delegate = self

        // Ghost Mode — borderless, floating, screen-capture invisible
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.sharingType = .none
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear

        // Liquid Glass panelinin görsel olarak yüzmesi için gerçek gölge
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false

        // SwiftUI içeriğinin arkasında gerçek bulanıklık katmanı olarak NSVisualEffectView
        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 20
        effectView.layer?.masksToBounds = true

        let runtimeContainer = ZeroLoseRuntimeContainer.shared
        let hostingView = NSHostingView(
            rootView: ContentView(
                viewModel: runtimeContainer.shellViewModel,
                chatViewModel: runtimeContainer.chatViewModel,
                settingsViewModel: runtimeContainer.settingsViewModel,
                taskRuntimeViewModel: runtimeContainer.taskRuntimeViewModel,
                approvalViewModel: runtimeContainer.approvalViewModel,
                timelineProjection: runtimeContainer.timelineProjection,
                runtimeProjectionCoordinator: runtimeContainer.runtimeProjectionCoordinator,
                runtimeProjectionInitializationError: runtimeContainer.runtimeProjectionInitializationError
            )
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        effectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor)
        ])

        window.contentView = effectView
        
        restoreWindowPosition()
        applyMainWindowSizeFromDefaults(animated: false)
        applyWindowOpacityFromDefaults()
        
        logger.info("ZeroLose Window Initialized. Initial sharingType based on stealthMode.")
        
        // Apply initial stealth mode setting
        let initialStealthMode = UserDefaults.standard.bool(forKey: "stealthModeEnabled")
        updateSharingType(stealth: initialStealthMode)
        
        showWindow()
        
        // Observe stealthMode changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        
        // Start Hotkey Listener
        HotkeyManager.shared.onToggle = { [weak self] in
            self?.toggleVisibility()
        }
        HotkeyManager.shared.start()
    }
    
    @objc private func preferencesChanged() {
        let defaults = UserDefaults.standard
        let stealthEnabled = defaults.bool(forKey: "stealthModeEnabled")
        updateSharingType(stealth: stealthEnabled)
        applyWindowOpacityFromDefaults()
    }
    
    @objc private func appWillTerminate() {
        saveWindowFrame()
        if let teleprompterWindow {
            saveTeleprompterFrame(teleprompterWindow)
        }
    }
    
    /// Gizli mod ayarına göre pencere paylaşım türünü günceller.
    /// - Parameter stealth: true = ekran paylaşımında görünmez, false = görünür
    func updateSharingType(stealth: Bool) {
        let type: NSWindow.SharingType = stealth ? .none : .readOnly
        
        // Ana pencere, sayfalar, teleprompter vb. yakalamak için tüm uygulama pencerelerini döngüye al
        for window in NSApp.windows {
            window.sharingType = type
        }
        
        logger.info("\(stealth ? "👻" : "👁️") Stealth Mode \(stealth ? "active" : "inactive"): All windows set to \(stealth ? ".none" : ".readOnly")")
    }
    
    func updateMainWindowSize(width: Double, height: Double, animated: Bool = true) {
        guard let window = window else { return }
        
        let clampedWidth = max(350, min(width, 800))
        let clampedHeight = max(300, min(height, 1000))
        let targetSize = NSSize(width: clampedWidth, height: clampedHeight)
        
        let currentSize = window.contentRect(forFrameRect: window.frame).size
        guard abs(currentSize.width - targetSize.width) > 0.5 || abs(currentSize.height - targetSize.height) > 0.5 else {
            return
        }
        
        if animated {
            window.animator().setContentSize(targetSize)
        } else {
            window.setContentSize(targetSize)
        }
    }
    
    func updateWindowOpacity(_ opacity: Double) {
        let clamped = max(0.35, min(opacity, 1.0))
        let alpha = CGFloat(clamped)
        
        window?.alphaValue = alpha
        teleprompterWindow?.alphaValue = alpha
        settingsWindow?.alphaValue = alpha
    }
    
    private func applyMainWindowSizeFromDefaults(animated: Bool) {
        let defaults = UserDefaults.standard
        let width = defaults.double(forKey: "windowWidth")
        let height = defaults.double(forKey: "windowHeight")
        
        guard width > 0, height > 0 else { return }
        updateMainWindowSize(width: width, height: height, animated: animated)
    }
    
    private func applyWindowOpacityFromDefaults() {
        let rawValue = UserDefaults.standard.double(forKey: "windowOpacity")
        let resolvedValue = rawValue > 0 ? rawValue : 1.0
        updateWindowOpacity(resolvedValue)
    }
    
    private func restoreWindowPosition() {
        if let _ = NSScreen.main {
            let x = UserDefaults.standard.double(forKey: "windowPosX")
            let y = UserDefaults.standard.double(forKey: "windowPosY")
            let w = UserDefaults.standard.double(forKey: "windowWidth")
            let h = UserDefaults.standard.double(forKey: "windowHeight")
            
            if x != 0 || y != 0 {
                // Konumu geri yükle
                window.setFrameOrigin(NSPoint(x: x, y: y))
                // Kaydedilmişse boyutu geri yükle
                if w > 100 && h > 100 {
                    window.setContentSize(NSSize(width: w, height: h))
                }
            } else {
                if let screenRect = NSScreen.main?.visibleFrame {
                    let newOrigin = NSPoint(
                        x: screenRect.maxX - 480,
                        y: screenRect.maxY - 450
                    )
                    window.setFrameOrigin(newOrigin)
                }
            }
        }
    }
    
    // MARK: - NSWindowDelegate
    func windowDidMove(_ notification: Notification) {
        if let win = notification.object as? NSWindow {
            if win == self.window {
                saveWindowFrame()
            } else if win == self.teleprompterWindow {
                saveTeleprompterFrame(win)
            }
        }
    }
    
    func windowDidResize(_ notification: Notification) {
        if let win = notification.object as? NSWindow {
            if win == self.window {
                saveWindowFrame()
            } else if win == self.teleprompterWindow {
                saveTeleprompterFrame(win)
            }
        }
    }
    
    private func saveWindowFrame() {
        let frame = window.frame
        let contentSize = window.contentRect(forFrameRect: frame).size
        UserDefaults.standard.set(frame.origin.x, forKey: "windowPosX")
        UserDefaults.standard.set(frame.origin.y, forKey: "windowPosY")
        UserDefaults.standard.set(contentSize.width, forKey: "windowWidth")
        UserDefaults.standard.set(contentSize.height, forKey: "windowHeight")
    }
    
    private func restoreTeleprompterSize() -> NSSize {
        let defaults = UserDefaults.standard
        let savedWidth = defaults.double(forKey: WindowPreferenceKeys.teleprompterWidth)
        let savedHeight = defaults.double(forKey: WindowPreferenceKeys.teleprompterHeight)
        
        let defaultSize = NSSize(width: 430, height: 300)
        guard savedWidth > 0, savedHeight > 0 else { return defaultSize }
        
        let clampedWidth = max(320, min(savedWidth, 1200))
        let clampedHeight = max(220, min(savedHeight, 1000))
        return NSSize(width: clampedWidth, height: clampedHeight)
    }
    
    private func saveTeleprompterFrame(_ window: NSWindow) {
        let frame = window.frame
        let contentSize = window.contentRect(forFrameRect: window.frame).size
        UserDefaults.standard.set(frame.origin.x, forKey: WindowPreferenceKeys.teleprompterPosX)
        UserDefaults.standard.set(frame.origin.y, forKey: WindowPreferenceKeys.teleprompterPosY)
        UserDefaults.standard.set(contentSize.width, forKey: WindowPreferenceKeys.teleprompterWidth)
        UserDefaults.standard.set(contentSize.height, forKey: WindowPreferenceKeys.teleprompterHeight)
    }

    private func restoreTeleprompterFrame(size: NSSize) -> NSRect {
        let defaults = UserDefaults.standard
        let savedX = defaults.double(forKey: WindowPreferenceKeys.teleprompterPosX)
        let savedY = defaults.double(forKey: WindowPreferenceKeys.teleprompterPosY)

        if savedX != 0 || savedY != 0 {
            return NSRect(x: savedX, y: savedY, width: size.width, height: size.height)
        }

        return NSRect(x: 300, y: 300, width: size.width, height: size.height)
    }
    
    func showWindow() {
        logger.info("👁️ Showing overlay window")
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
    
    func hideWindow() {
        logger.info("🙈 Hiding overlay window")
        window.orderOut(nil)
    }
    
    func toggleVisibility() {
        logger.debug("⌨️ Toggle visibility request. currentlyVisible=\(self.window.isVisible)")
        if window.isVisible {
            hideWindow()
        } else {
            showWindow()
        }
    }
    
    // MARK: - Ayarlar Penceresi
    
    func toggleSettingsWindow() {
        if settingsWindow != nil {
            closeSettingsWindow()
        } else {
            showSettingsWindow()
        }
    }
    
    func showSettingsWindow() {
        if isClosingSettingsWindow {
            logger.debug("Settings close in progress; skipping open request.")
            return
        }
        
        if let existingWindow = settingsWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            existingWindow.orderFrontRegardless()
            return
        }
        
        let settingsWin = SettingsWindow(
            contentRect: NSRect(x: 260, y: 220, width: 680, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        settingsWin.title = "ZeroLose Settings"
        settingsWin.titlebarAppearsTransparent = true
        settingsWin.titleVisibility = .hidden
        settingsWin.level = .floating
        settingsWin.isReleasedWhenClosed = false
        settingsWin.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        settingsWin.isOpaque = false
        settingsWin.backgroundColor = .clear
        settingsWin.hasShadow = true
        
        let stealthEnabled = UserDefaults.standard.bool(forKey: "stealthModeEnabled")
        settingsWin.sharingType = stealthEnabled ? .none : .readOnly
        let settingsOpacityRaw = UserDefaults.standard.double(forKey: "windowOpacity")
        settingsWin.alphaValue = CGFloat(max(0.35, min(settingsOpacityRaw > 0 ? settingsOpacityRaw : 1.0, 1.0)))
        
        let settingsView = SettingsView(
            isPresented: Binding(
                get: { [weak self] in self?.settingsWindow != nil },
                set: { [weak self] show in
                    if !show { self?.closeSettingsWindow() }
                }
            ),
            viewModel: ZeroLoseRuntimeContainer.shared.settingsViewModel
        )
        
        // Ayarların arkasında gerçek bulanıklık katmanı olarak NSVisualEffectView
        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 16
        effectView.layer?.masksToBounds = true

        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor)
        ])
        
        settingsWin.contentView = effectView
        settingsWin.delegate = self
        settingsWindow = settingsWin
        
        settingsWin.makeKeyAndOrderFront(nil)
        settingsWin.orderFrontRegardless()
    }
    
    func closeSettingsWindow() {
        guard !isClosingSettingsWindow, let win = settingsWindow else { return }
        isClosingSettingsWindow = true
        settingsWindow = nil
        
        win.orderOut(nil)
        
        DispatchQueue.main.async { [weak self] in
            win.close()
            self?.isClosingSettingsWindow = false
            self?.logger.info("⚙️ Settings window closed safely")
        }
    }
    
    // MARK: - Teleprompter Penceresi
    
    func toggleTeleprompterWindow() {
        if teleprompterWindow != nil {
            closeTeleprompterWindow()
        } else {
            showTeleprompterWindow()
        }
    }
    
    func showTeleprompterWindow() {
        if isClosingTeleprompterWindow {
            logger.debug("Teleprompter close in progress; skipping open request.")
            return
        }
        
        if let existingWindow = teleprompterWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            existingWindow.orderFrontRegardless()
            return
        }
        
        // Bilinen son boyutu geri yükle; ilk başlatmada varsayılana düş
        let restoredSize = restoreTeleprompterSize()
        let restoredFrame = restoreTeleprompterFrame(size: restoredSize)
        
        let tpWindow = TeleprompterWindow(
            contentRect: restoredFrame,
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        tpWindow.level = .floating
        tpWindow.backgroundColor = .clear
        tpWindow.isOpaque = false
        tpWindow.hasShadow = true
        tpWindow.isMovableByWindowBackground = true
        tpWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        tpWindow.isReleasedWhenClosed = false
        
        // Teleprompter Penceresine gizli modu uygula
        let stealthEnabled = UserDefaults.standard.bool(forKey: "stealthModeEnabled")
        tpWindow.sharingType = stealthEnabled ? .none : .readOnly
        let tpOpacityRaw = UserDefaults.standard.double(forKey: "windowOpacity")
        tpWindow.alphaValue = CGFloat(max(0.35, min(tpOpacityRaw > 0 ? tpOpacityRaw : 1.0, 1.0)))
        
        let tpView = TeleprompterView(
            isPresented: Binding(
                get: { [weak self] in self?.teleprompterWindow != nil },
                set: { [weak self] show in
                    if !show { self?.closeTeleprompterWindow() }
                }
            )
        )
        
        // Teleprompter'ın arkasında gerçek bulanıklık katmanı olarak NSVisualEffectView
        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true

        let hostingView = NSHostingView(rootView: tpView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor)
        ])
        
        tpWindow.contentView = effectView
        tpWindow.delegate = self
        
        teleprompterWindow = tpWindow
        
        tpWindow.makeKeyAndOrderFront(nil)
        tpWindow.orderFrontRegardless()
    }
    
    func closeTeleprompterWindow() {
        guard !isClosingTeleprompterWindow, let win = teleprompterWindow else { return }
        isClosingTeleprompterWindow = true
        saveTeleprompterFrame(win)
        
        // SwiftUI durum yarışlarını önlemek için binding destekli "isPresented" değerini hemen false yap.
        teleprompterWindow = nil
        
        // Algılanan duyarlılığı artırmak için hemen gizle
        win.orderOut(nil)
        
        // SwiftUI yeniden giriş sorunlarını/çökmelerini önlemek için sonraki runloop'ta kapat
        DispatchQueue.main.async { [weak self] in
            win.close()
            self?.isClosingTeleprompterWindow = false
            self?.logger.info("📚 Teleprompter window closed safely")
        }
    }
    
    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        
        if closingWindow is SettingsWindow {
            settingsWindow = nil
            isClosingSettingsWindow = false
        }
        
        if closingWindow is TeleprompterWindow {
            teleprompterWindow = nil
            isClosingTeleprompterWindow = false
        }
    }
}

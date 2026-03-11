import Cocoa
import SwiftUI
import Observation
import os

// Custom Window Class to allow Borderless windows to become Key (Focusable)
class GhostWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}

// Borderless window for Teleprompter
class TeleprompterWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}

// Dedicated window for Settings
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
    
    // Use the container to get the shared VM
    private var viewModel: GhostViewModel {
        return DependencyContainer.shared.ghostViewModel
    }
    
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
        
        // 👻 GHOST MODE ENGAGED
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        
        // Fully disable window sharing to remain invisible to any screen recording
        window.sharingType = .none
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        
        let vm = DependencyContainer.shared.ghostViewModel
        window.contentView = NSHostingView(rootView: ContentView(viewModel: vm))
        
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
    
    /// Update window sharing type based on stealth mode setting
    /// - Parameter stealth: true = invisible to screen sharing, false = visible
    func updateSharingType(stealth: Bool) {
        let type: NSWindow.SharingType = stealth ? .none : .readOnly
        
        // Loop through all app windows to catch main window, sheets, teleprompter, etc.
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
                // Restore Pos
                window.setFrameOrigin(NSPoint(x: x, y: y))
                // Restore Size if saved
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
    
    // MARK: - Settings Window
    
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
            contentRect: NSRect(x: 260, y: 220, width: 420, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        settingsWin.title = "ZeroLose Settings"
        settingsWin.level = .floating
        settingsWin.isReleasedWhenClosed = false
        settingsWin.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
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
            )
        )
        
        settingsWin.contentView = NSHostingView(rootView: settingsView)
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
    
    // MARK: - Teleprompter Window
    
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
        
        // Restore last known size; fallback to default on first launch
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
        
        // Apply stealth mode to TeleprompterWindow
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
        
        tpWindow.contentView = NSHostingView(rootView: tpView)
        tpWindow.delegate = self
        
        teleprompterWindow = tpWindow
        
        tpWindow.makeKeyAndOrderFront(nil)
        tpWindow.orderFrontRegardless()
    }
    
    func closeTeleprompterWindow() {
        guard !isClosingTeleprompterWindow, let win = teleprompterWindow else { return }
        isClosingTeleprompterWindow = true
        saveTeleprompterFrame(win)
        
        // Make binding-backed "isPresented" false immediately to avoid SwiftUI state races.
        teleprompterWindow = nil
        
        // Hide immediately to improve perceived responsiveness
        win.orderOut(nil)
        
        // Close on next runloop to avoid SwiftUI re-entrancy issues/crashes
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

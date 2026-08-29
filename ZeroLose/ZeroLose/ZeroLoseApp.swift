import SwiftUI
import AppKit
import CoreGraphics

@main
struct ZeroLoseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // WindowManager ana kaplama penceresini yönetir
        // Özel NSWindow kullandığımız için WindowGroup gerekmiyor
        Settings {
            EmptyView()
        }
    }
}

private struct UITestRootView: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("ZeroLose UI Test Mode")
                .font(.title2.weight(.semibold))
            Text("UI harness active")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var windowManager = WindowManager.shared
    var uiTestWindow: NSWindow?
    private let isUITesting = ProcessInfo.processInfo.arguments.contains("-ui-testing")
    private let isUnitTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        if isUITesting {
            NSApp.setActivationPolicy(.regular)
            
            let window = NSWindow(
                contentRect: NSRect(x: 120, y: 120, width: 900, height: 640),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "ZeroLose UI Test"
            window.contentView = NSHostingView(rootView: UITestRootView())
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            self.uiTestWindow = window
            return
        }

        if isUnitTesting {
            NSApp.setActivationPolicy(.accessory)
            return
        }

        // ZeroLose is a menu-bar utility. Keep it out of the Dock and App Switcher
        // on every normal launch; the explicit UI-test path remains regular.
        NSApp.setActivationPolicy(.accessory)

        // Bu makinedeki mevcut OpenCode Go / Zen üyeliğini yeniden kullan, böylece
        // OpenCode sağlayıcısı anahtarı yeniden yapıştırmadan hemen çalışır.
        Secrets.importOpenCodeKeysIfNeeded()
        
        // Keep the utility available through its status-item/window hotkey without
        // activating it on launch; this also avoids an unexpected foreground jump.
        
        // 1. Durum Çubuğu Öğesini Kur
        requestScreenCapturePermissionIfNeeded()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            // Gizleme: sıradan bir gözlemcinin bunun bir AI asistanı olduğunu
            // anlayamaması için klavye simgesi. Aşağıdaki menü gerçek klavye uygulaması
            // seçeneklerini yansıtır.
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboard")
            button.action = #selector(menuBarClicked)
        }
        
        // 2. Kaplama Penceresini Başlat
        windowManager.setupWindow()
    }

    /// macOS, ScreenCaptureKit (`SCStream` / `SCScreenshotManager`) sistem sesini veya
    /// pikselleri yakalamadan önce Ekran Kaydı izni gerektirir. Başlatmada bir kez
    /// iste; zaten verilmişse çağrı işlem yapmaz.
    private func requestScreenCapturePermissionIfNeeded() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }
    
    @objc func menuBarClicked() {
        let menu = NSMenu()
        // Bu etiketler bilerek normal bir klavye/yardımcı uygulaması gibi görünür,
        // böylece menü çubuğuna göz atan yetkisiz bir kişi şüpheli bir şey görmez.
        // Gizlenmiş "Keyboard Settings" seçimi yine de kaplamamızı açar/kapatır.
        let kbHeader = NSMenuItem(title: "Keyboard", action: nil, keyEquivalent: "")
        kbHeader.isEnabled = false
        menu.addItem(kbHeader)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Show Keyboard Settings…", action: #selector(toggleOverlay), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Show Emoji & Symbols", action: #selector(toggleOverlay), keyEquivalent: "e"))
        menu.addItem(NSMenuItem(title: "Text Input Feedback", action: #selector(toggleOverlay), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "About Keyboard", action: #selector(toggleOverlay), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let quitTitle = "Quit ZeroLose"
        menu.addItem(NSMenuItem(title: quitTitle, action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil) // Menüyü hemen göster
        statusItem?.menu = nil
    }
    
    @objc func toggleOverlay() {
        windowManager.toggleVisibility()
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

import SwiftUI
import AppKit

@main
struct ZeroLoseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // WindowManager handles the main overlay window
        // No WindowGroup needed since we use custom NSWindow
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

        // Check user preference for stealth mode
        let isStealth = UserDefaults.standard.bool(forKey: "stealthModeEnabled")
        
        if isStealth {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
            // Ensure app comes to foreground if not in stealth mode
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        
        // 1. Setup Status Bar Item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            // "sun.max" resembles the Keyboard Brightness / Display Brightness icon
            button.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Brightness")
            button.action = #selector(menuBarClicked)
        }
        
        // 2. Initialize the Overlay Window
        windowManager.setupWindow()
    }
    
    @objc func menuBarClicked() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Toggle Overlay", action: #selector(toggleOverlay), keyEquivalent: "t"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit ZeroLose", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil) // Show menu immediately
        statusItem?.menu = nil
    }
    
    @objc func toggleOverlay() {
        windowManager.toggleVisibility()
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

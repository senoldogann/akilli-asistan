import Carbon
import Cocoa
import Combine
import os

final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    // Mevcut ayarlar UI bağlamasıyla uyumluluk için korunan tarihsel ad.
    @Published private(set) var isPermissionGranted: Bool = true

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let logger = Logger.app
    private let hotkeyID = EventHotKeyID(signature: OSType(0x5A4C4F53), id: 1) // "ZLOS"
    private let eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    
    // WindowManager tarafından ayarlanan geri çağrı
    var onToggle: (() -> Void)?
    
    private init() {}
    
    func start() {
        guard hotKeyRef == nil else { return }

        if eventHandlerRef == nil {
            let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            var eventType = eventType
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                hotkeyEventHandler,
                1,
                &eventType,
                context,
                &eventHandlerRef
            )

            guard status == noErr else {
                logger.error("❌ Failed to install hotkey event handler. OSStatus: \(status)")
                isPermissionGranted = false
                return
            }
        }

        let hotkey = hotkeyID
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_B),
            UInt32(cmdKey),
            hotkey,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr else {
            logger.error("❌ Failed to register Cmd+B hotkey. OSStatus: \(status)")
            self.isPermissionGranted = false
            return
        }

        self.isPermissionGranted = true
        logger.info("⌨️ Global Hotkey (Cmd+B) registered")
    }

    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    fileprivate func handleHotkeyEvent(_ eventRef: EventRef?) -> OSStatus {
        guard let eventRef else { return noErr }

        var incomingHotkeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &incomingHotkeyID
        )

        guard status == noErr else {
            logger.error("❌ Failed to read hotkey payload. OSStatus: \(status)")
            return status
        }

        guard incomingHotkeyID.signature == hotkeyID.signature,
              incomingHotkeyID.id == hotkeyID.id else {
            return noErr
        }

        onToggle?()
        return noErr
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}

private func hotkeyEventHandler(
    nextHandler: EventHandlerCallRef?,
    theEvent: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return noErr }

    let hotkeyManager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    return hotkeyManager.handleHotkeyEvent(theEvent)
}

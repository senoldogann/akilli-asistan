import SwiftUI
import Observation

/// Uygulama geneli tema deposu.
///
/// `Color.brandPrimary`, `UserDefaults`'ı okuyan bir `static var`'dır, ancak SwiftUI
/// bu okumaları gözlemleyemez — bu yüzden temayı değiştirmek görünüm ağacını geçersiz
/// kılmıyordu. Bu `@Observable` singleton, tema değişikliklerini her yerde tepkisel hale
/// getirir: `ThemeStore.shared.accent`'i okuyan her görünüm, tema değiştiğinde ayrı
/// NSWindow'lar dahil yeniden çizilir.
@Observable
@MainActor
final class ThemeStore {
    static let shared = ThemeStore()

    private(set) var themeName: String

    init() {
        themeName = UserDefaults.standard.string(forKey: "selectedThemeName") ?? "Red"
        observeUserDefaultsChanges()
    }

    var accent: Color {
        Self.accent(for: themeName)
    }

    func apply(_ name: String) {
        themeName = name
        UserDefaults.standard.set(name, forKey: "selectedThemeName")
    }

    nonisolated static func accent(for themeName: String) -> Color {
        switch themeName {
        case "Red":      return Color(red: 242.0/255.0, green: 78.0/255.0, blue: 78.0/255.0)
        case "Orange":   return Color.orange
        case "Blue":     return Color(red: 0.2, green: 0.6, blue: 1.0)
        case "Purple":   return Color(red: 0.7, green: 0.3, blue: 1.0)
        case "Green":    return Color(red: 0.2, green: 0.85, blue: 0.5)
        case "Graphite": return Color(white: 0.55)
        default:         return Color(red: 242.0/255.0, green: 78.0/255.0, blue: 78.0/255.0)
        }
    }

    private nonisolated func observeUserDefaultsChanges() {
        // macOS @AppStorage, kardeş bir NSWindow'u güvenilir şekilde geçersiz kılmaz.
        // Ayarlardaki bir değişikliğin `accent`'i çizen her pencereyi güncellemesi için
        // UserDefaults'ı doğrudan gözlemle.
        let center = NotificationCenter.default
        let token = center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.themeName = UserDefaults.standard.string(forKey: "selectedThemeName") ?? "Red"
            }
        }
        // Keep the token alive for the lifetime of the singleton.
        _ = token
    }
}

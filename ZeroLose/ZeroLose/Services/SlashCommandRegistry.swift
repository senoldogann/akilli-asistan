import Foundation

struct SlashCommand: Identifiable {
    let id = UUID()
    let command: String
    let description: String
    let category: String // "Media", "System", "Web", "General"
}

struct SlashCommandRegistry {
    static let commands: [SlashCommand] = [
        // System
        SlashCommand(command: "/Desktop", description: "Masaüstünü düzenle ve hizala", category: "System"),
        SlashCommand(command: "/Trash", description: "Çöp kutusunu güvenli şekilde boşalt", category: "System"),
        SlashCommand(command: "/Mute", description: "Sesi kapat", category: "System"),
        SlashCommand(command: "/Unmute", description: "Sesi aç", category: "System"),
        SlashCommand(command: "/Volume 50", description: "Ses seviyesini ayarla (0-100)", category: "System"),
        SlashCommand(command: "/Lock", description: "Ekranı anında kilitle", category: "System"),
        SlashCommand(command: "/Sleep", description: "Mac'i uyku moduna al", category: "System"),
        SlashCommand(command: "/Screensaver", description: "Ekran koruyucuyu başlat", category: "System"),
        SlashCommand(command: "/Screenshot", description: "Ekran görüntüsünü panoya al", category: "System"),
        
        // Web
        SlashCommand(command: "/Google query", description: "Google'da arama yap", category: "Web"),
        SlashCommand(command: "/Youtube query", description: "YouTube arama sonuçlarını aç", category: "Web"),
        SlashCommand(command: "/GitHub owner/repo", description: "GitHub repo veya arama aç", category: "Web"),
        SlashCommand(command: "/News topic", description: "Google News üzerinde konu ara", category: "Web"),
        
        // Media
        SlashCommand(command: "/Music play|pause|next|prev", description: "Music uygulamasını kontrol et", category: "Media"),
        SlashCommand(command: "/Spotify play|pause|next|prev", description: "Spotify kontrol komutları", category: "Media"),
        
        // Apps
        SlashCommand(command: "/App open Safari", description: "Uygulama aç", category: "Apps"),
        SlashCommand(command: "/App close Safari", description: "Uygulama kapat", category: "Apps"),
        SlashCommand(command: "/Open Safari", description: "Kısa yol: uygulama aç", category: "Apps"),
        SlashCommand(command: "/Close Safari", description: "Kısa yol: uygulama kapat", category: "Apps"),

        // Files
        SlashCommand(command: "/Fs pwd", description: "Aktif çalışma klasörünü göster", category: "Files"),
        SlashCommand(command: "/Fs ls ~/Desktop", description: "Klasör içeriğini listele", category: "Files"),
        SlashCommand(command: "/Fs mkdir ~/Desktop/Test", description: "Yeni klasör oluştur", category: "Files"),
        SlashCommand(command: "/Fs touch ~/Desktop/note.txt", description: "Yeni dosya oluştur", category: "Files"),
        SlashCommand(command: "/Fs read ~/Desktop/note.txt", description: "Dosya oku ve bağlama al", category: "Files"),
        SlashCommand(command: "/Fs write ~/Desktop/note.txt | Merhaba", description: "Dosyaya içerik yaz", category: "Files"),
        SlashCommand(command: "/Fs append ~/Desktop/note.txt | Yeni satır", description: "Dosyaya ekleme yap", category: "Files"),
        SlashCommand(command: "/Fs mv ~/Desktop/a.txt -> ~/Desktop/b.txt", description: "Dosya/klasör taşı", category: "Files"),
        SlashCommand(command: "/Fs replace eski => yeni", description: "Son okunan dosyada değiştir", category: "Files"),
        SlashCommand(command: "/Fs replace-dir ~/Desktop/proje | foo => bar", description: "Klasörde toplu düzenleme", category: "Files"),
        SlashCommand(command: "/Fs context", description: "Aktif dosya bağlamını göster", category: "Files"),
        SlashCommand(command: "/Fs sudo ls /var/root", description: "Yönetici yetkisiyle shell komutu çalıştır", category: "Files"),

        SlashCommand(command: "/Help", description: "Slash komutlarını listeler", category: "General")
    ]
}

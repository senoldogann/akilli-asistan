import Foundation

/// Ajanın kullanabileceği tek bir yeteneğin (araç) yapılandırılmış tanımı.
/// Sistem promptu ve ajan karar mantığı bu tanımlardan beslenir, böylece
/// "ajan ne yapabilir" bilgisi tek bir doğruluk kaynağından gelir.
struct AgentCapability: Sendable, Equatable {
    let id: String
    let displayName: String
    let summary: String
    let whenToUse: String
    let actionType: String
    let example: String
    /// `true` ise bu araç kullanıcı onayı gerektirir (mutasyon: yazma, silme,
    /// uygulama kontrolü). `false` ise salt bilgi aracıdır ve her zaman kullanılabilir.
    let requiresApproval: Bool
}

/// Ajanın yeteneklerinin tek doğruluk kaynağı.
/// Hem sistem promptuna enjekte edilen "YETENEKLERİM" bloğunu hem de yapısal
/// karar rehberini üretir. Bu kaynak değişirse ajan davranışı tek noktadan güncellenir.
enum AgentCapabilityRegistry {

    /// Ajanın aktif olarak kullanabileceği yeteneklerin tam listesi.
    nonisolated static let all: [AgentCapability] = [
        AgentCapability(
            id: "web_search",
            displayName: "Web Arama (Tavily)",
            summary: "Canlı internette güncel bilgi, doğrulama ve kaynak ara.",
            whenToUse: "Güncel haber, fiyat, tarih, istatistik, doğrulanmamış bilgi, benchmark veya benim bilmediğim konu.",
            actionType: "web_search",
            example: "[ACTION: {\"type\": \"web_search\", \"query\": \"latest SwiftUI release notes\"}]",
            requiresApproval: false
        ),
        AgentCapability(
            id: "file",
            displayName: "Dosya Sistemi",
            summary: "Dosya/klasör listele, oku, oluştur, düzenle, taşı, değiştir.",
            whenToUse: "Kullanıcı dosya, klasör, kod, dizin, proje ağacı, yapılandırma istediğinde.",
            actionType: "file",
            example: "[ACTION: {\"type\": \"file\", \"operation\": \"read\", \"path\": \"/Users/dogan/Desktop/README.md\"}]",
            requiresApproval: false
        ),
        AgentCapability(
            id: "shell",
            displayName: "Terminal (salt-okunur)",
            summary: "Güvenli, yalnızca okuma amaçlı terminal komutları (pwd, ls, rg, cat, git status).",
            whenToUse: "Kullanıcı gerçekte çıktı istediğinde; yalnızca zararsız salt-okunur komutlarda.",
            actionType: "shell",
            example: "[ACTION: {\"type\": \"shell\", \"payload\": \"ls -la /Users/dogan\"}]",
            requiresApproval: false
        ),
        AgentCapability(
            id: "applescript",
            displayName: "Uygulama & Masaüstü Kontrolü",
            summary: "Uygulama aç/kapat, ses, ekran, Finder, tarayıcı, Spotify kontrolü.",
            whenToUse: "Kullanıcı bir uygulamayı veya masaüstü/OS davranışını değiştirmek istediğinde.",
            actionType: "applescript",
            example: "[ACTION: {\"type\": \"applescript\", \"payload\": \"tell application \\\"Spotify\\\" to playpause\"}]",
            requiresApproval: true
        ),
        AgentCapability(
            id: "screenshot",
            displayName: "Ekran Analizi",
            summary: "Ekran görüntüsü alıp görsel olarak analiz et.",
            whenToUse: "Kullanıcı ekrandaki bir şeyi sormasını istediğinde veya görsel inceleme gerektiğinde.",
            actionType: "screenshot",
            example: "[ACTION: {\"type\": \"screenshot\"}]",
            requiresApproval: false
        ),
        AgentCapability(
            id: "audio",
            displayName: "Sesli Giriş",
            summary: "Mikrofon ile sesli soru dinle ve metne çevir.",
            whenToUse: "Kullanıcı sesli olarak bir şey sormak istediğinde.",
            actionType: "audio",
            example: "[ACTION: {\"type\": \"audio\"}]",
            requiresApproval: false
        ),
        AgentCapability(
            id: "clipboard",
            displayName: "Pano",
            summary: "Kopyalanan metni oku ve analiz et.",
            whenToUse: "Kullanıcı panodaki içerikten bahsettiğinde veya panoyla çalışmak istediğinde.",
            actionType: "clipboard",
            example: "[ACTION: {\"type\": \"clipboard\"}]",
            requiresApproval: false
        ),
        AgentCapability(
            id: "system_status",
            displayName: "Sistem Durumu",
            summary: "CPU, bellek, disk, pil ve sistem sağlığı bilgisi.",
            whenToUse: "Kullanıcı sistem performansı, kaynak kullanımı veya sağlık durumu sorduğunda.",
            actionType: "system_status",
            example: "[ACTION: {\"type\": \"system_status\"}]",
            requiresApproval: false
        ),
        AgentCapability(
            id: "computer_list",
            displayName: "Computer Use: Uygulama Listesi",
            summary: "Çalışan uygulamaları ve PID'lerini listele.",
            whenToUse: "Hangi uygulamayı açacağını/kontrol edeceğini bilmiyorsan veya bir uygulama adı verildiyse.",
            actionType: "computer_list",
            example: "[ACTION: {\"type\": \"computer_list\"}]",
            requiresApproval: false
        ),
        AgentCapability(
            id: "computer_status",
            displayName: "Computer Use: Durum / İzinler",
            summary: "Hangi iznin eksik olduğunu ve çalışan uygulamaları göster.",
            whenToUse: "Computer Use çalışmıyorsa, izin hatası görürsen veya hangi uygulamaların açık olduğunu bilmen gerektiğinde.",
            actionType: "computer_status",
            example: "[ACTION: {\"type\": \"computer_status\"}]",
            requiresApproval: false
        ),
        AgentCapability(
            id: "computer_snapshot",
            displayName: "Computer Use: Ekranı Oku",
            summary: "Bir uygulamanın etkileşimli öğelerini (buton, alan) koordinatlarıyla oku.",
            whenToUse: "Bir uygulamada bir işlem yapmadan önce neyin nerede olduğunu görmek istediğinde.",
            actionType: "computer_snapshot",
            example: "[ACTION: {\"type\": \"computer_snapshot\", \"app\": \"Chrome\"}]  // app yoksa ön plandaki uygulama",
            requiresApproval: false
        ),
        AgentCapability(
            id: "computer_click",
            displayName: "Computer Use: Tıkla",
            summary: "Bir uygulamadaki bir öğeye tıkla (arka plan güvenli, odak çalmaz).",
            whenToUse: "Bir buton, menü, satır veya alan üzerine tıklaman gerektiğinde.",
            actionType: "computer_click",
            example: "[ACTION: {\"type\": \"computer_click\", \"app\": \"Safari\", \"index\": \"5\"}]",
            requiresApproval: true
        ),
        AgentCapability(
            id: "computer_type",
            displayName: "Computer Use: Yaz",
            summary: "Hedef uygulamaya metin yaz.",
            whenToUse: "Bir arama kutusu, form veya metin alanına veri girmen gerektiğinde.",
            actionType: "computer_type",
            example: "[ACTION: {\"type\": \"computer_type\", \"text\": \"hello\"}]  // pid yoksa ön plandaki uygulama",
            requiresApproval: true
        ),
        AgentCapability(
            id: "computer_press",
            displayName: "Computer Use: Tuş",
            summary: "Klavye kısayolu gönder (cmd+c, return, ctrl+shift+a).",
            whenToUse: "Kopyalama, yapıştırma, Enter'a basma, kısayol çalıştırma gerektiğinde.",
            actionType: "computer_press",
            example: "[ACTION: {\"type\": \"computer_press\", \"pid\": \"1234\", \"key\": \"cmd+c\"}]",
            requiresApproval: true
        ),
        AgentCapability(
            id: "computer_scroll",
            displayName: "Computer Use: Kaydır",
            summary: "Bir uygulamada yukarı/aşağı kaydır.",
            whenToUse: "Bir liste, akış veya belge içinde gezinmen gerektiğinde.",
            actionType: "computer_scroll",
            example: "[ACTION: {\"type\": \"computer_scroll\", \"pid\": \"1234\", \"x\": \"500\", \"y\": \"400\", \"amount\": \"-300\"}]",
            requiresApproval: true
        ),
        AgentCapability(
            id: "computer_ocr",
            displayName: "Computer Use: Ekrandaki Metni Oku",
            summary: "Ekrandaki görünür metinleri (OCR) koordinatlarıyla listele.",
            whenToUse: "AX ağacı boş/eksik olan uygulamalarda (canvas, oyun, bazı Electron) metni bulmak gerektiğinde.",
            actionType: "computer_ocr",
            example: "[ACTION: {\"type\": \"computer_ocr\", \"pid\": \"1234\"}]",
            requiresApproval: false
        ),
        AgentCapability(
            id: "computer_clicktext",
            displayName: "Computer Use: Metne Tıkla (OCR)",
            summary: "Ekrandaki bir metne OCR ile koordinatını bulup tıkla.",
            whenToUse: "AX ağacı olmayan uygulamalarda görünen bir metne tıklaman gerektiğinde.",
            actionType: "computer_clicktext",
            example: "[ACTION: {\"type\": \"computer_clicktext\", \"pid\": \"1234\", \"text\": \"Gönder\"}]",
            requiresApproval: true
        ),
        AgentCapability(
            id: "computer_launch",
            displayName: "Computer Use: Uygulama Başlat",
            summary: "Bir uygulamayı öne getir veya başlat; PID'ini döndür.",
            whenToUse: "Bir uygulama açık değilse veya kontrol etmeden önce öne getirmen gerektiğinde.",
            actionType: "computer_launch",
            example: "[ACTION: {\"type\": \"computer_launch\", \"name\": \"Safari\"}]",
            requiresApproval: false
        ),
        AgentCapability(
            id: "computer_clicklabel",
            displayName: "Computer Use: Etikete Tıkla (AX)",
            summary: "Bir öğeye metniyle (label değeri) tıkla; indeks ezberleme yok.",
            whenToUse: "Öğenin görünen metnini biliyorsan (örn. 'Gönder', 'Kaydet').",
            actionType: "computer_clicklabel",
            example: "[ACTION: {\"type\": \"computer_clicklabel\", \"app\": \"Chrome\", \"target\": \"Kaydol\"}]",
            requiresApproval: true
        ),
        AgentCapability(
            id: "computer_inspect",
            displayName: "Computer Use: Hedefi İncele",
            summary: "Bir hedef metni hangi kaynaktan (AX/OCR) ne güvenle bulduğunu raporla.",
            whenToUse: "Bir metne tıklamadan önce belirsizlik (çok eşleşme/disabled/offscreen) olup olmadığını kontrol etmek istediğinde.",
            actionType: "computer_inspect",
            example: "[ACTION: {\"type\": \"computer_inspect\", \"app\": \"Chrome\", \"target\": \"Gönder\"}]",
            requiresApproval: false
        ),
        AgentCapability(
            id: "computer_interact",
            displayName: "Computer Use: Zincirli Etkileşim",
            summary: "Tek çağrıda tıkla → yaz → tuş bas. Round-trip'i azaltır.",
            whenToUse: "Bir alanı doldurup Enter'a basmak gibi çok adımlı tek işlem gerektiğinde.",
            actionType: "computer_interact",
            example: "[ACTION: {\"type\": \"computer_interact\", \"pid\": \"1234\", \"target\": \"Arama\", \"text\": \"hello\", \"pressKey\": \"return\"}]",
            requiresApproval: true
        ),
        AgentCapability(
            id: "computer_drag",
            displayName: "Computer Use: Sürükle",
            summary: "Bir noktadan diğerine sürükle (dosya taşı, kaydırıcı, panel).",
            whenToUse: "Bir öğeyi başka bir yere sürüklemen veya boyut değiştirmen gerektiğinde.",
            actionType: "computer_drag",
            example: "[ACTION: {\"type\": \"computer_drag\", \"pid\": \"1234\", \"fromX\": \"100\", \"fromY\": \"200\", \"toX\": \"400\", \"toY\": \"200\"}]",
            requiresApproval: true
        ),
        AgentCapability(
            id: "computer_setvalue",
            displayName: "Computer Use: Değer Yaz (AXValue)",
            summary: "Bir metin alanına doğrudan değer yaz (klavye olayı göndermez).",
            whenToUse: "Yazma (type) sessizce başarısız oluyorsa, güvenli/sandbox/şifre alanlarında.",
            actionType: "computer_setvalue",
            example: "[ACTION: {\"type\": \"computer_setvalue\", \"pid\": \"1234\", \"index\": \"10\", \"value\": \"hello\"}]",
            requiresApproval: true
        ),
        AgentCapability(
            id: "computer_fill",
            displayName: "Computer Use: Form Alanı Doldur",
            summary: "Bir form alanını etiketiyle (örn. 'E-posta') değerle doldur.",
            whenToUse: "Tarayıcı/web formunda belirli bir alanı doldurman gerektiğinde (index yerine etiketle).",
            actionType: "computer_fill",
            example: "[ACTION: {\"type\": \"computer_fill\", \"app\": \"Chrome\", \"label\": \"E-posta\", \"value\": \"ornek@site.com\"}]",
            requiresApproval: true
        ),
        AgentCapability(
            id: "computer_submit",
            displayName: "Computer Use: Formu Gönder",
            summary: "Formu gönderir; butona tıklayamazsa klavye Tab+Return'a geçer.",
            whenToUse: "Tarayıcı web formunda submit (Kaydol/Gönder) yapman gerektiğinde.",
            actionType: "computer_submit",
            example: "[ACTION: {\"type\": \"computer_submit\", \"app\": \"Chrome\", \"target\": \"Kaydol\"}]",
            requiresApproval: true
        ),
        AgentCapability(
            id: "browser_navigate",
            displayName: "Browser: Sayfa Aç (CDP)",
            summary: "Bir URL'i CDP ile aç (formu native-hız DOM kontrolüne hazırla).",
            whenToUse: "Tarayıcıda bir sayfa/formu doldurmak istediğinde ve DOM kontrolü gerektiğinde.",
            actionType: "browser_navigate",
            example: "[ACTION: {\"type\": \"browser_navigate\", \"url\": \"https://example.com\"}]",
            requiresApproval: false
        ),
        AgentCapability(
            id: "browser_fill",
            displayName: "Browser: Alan Doldur (CDP)",
            summary: "Bir form alanını CSS seçicisiyle doğrudan doldur (native hız).",
            whenToUse: "CDP bağlı bir sayfada alanı kesin ve hızlı doldurman gerektiğinde.",
            actionType: "browser_fill",
            example: "[ACTION: {\"type\": \"browser_fill\", \"selector\": \"#email\", \"value\": \"ornek@site.com\"}]",
            requiresApproval: true
        ),
        AgentCapability(
            id: "browser_click",
            displayName: "Browser: Tıkla (CDP)",
            summary: "Bir DOM öğesine seçiciyle tıkla (native kesinlik).",
            whenToUse: "CDP bağlı sayfada buton/bağlantıya tıklaman gerektiğinde.",
            actionType: "browser_click",
            example: "[ACTION: {\"type\": \"browser_click\", \"selector\": \"button[type=submit]\"}]",
            requiresApproval: true
        ),
        AgentCapability(
            id: "browser_audit",
            displayName: "Browser: Sayfa İncele (CDP)",
            summary: "Sayfanın form alanları + butonlarının DOM özetini listele.",
            whenToUse: "CDP bağlı sayfada hangi alanların/butonların olduğunu görmek istediğinde.",
            actionType: "browser_audit",
            example: "[ACTION: {\"type\": \"browser_audit\"}]",
            requiresApproval: false
        ),
        AgentCapability(
            id: "computer_wait",
            displayName: "Computer Use: Bekle (poll)",
            summary: "Bir öğenin görünmesini/kaybolmasını bekler (doğrulama).",
            whenToUse: "Tıklama/yazma sonrası UI'ın oturmasını beklemen gerektiğinde.",
            actionType: "computer_wait",
            example: "[ACTION: {\"type\": \"computer_wait\", \"pid\": \"1234\", \"target\": \"Kaydedildi\", \"timeout\": \"5\"}]",
            requiresApproval: false
        ),
        AgentCapability(
            id: "stop",
            displayName: "İşlemi Durdur",
            summary: "Tekrarlayan görevleri veya çalışan işlemleri durdur.",
            whenToUse: "Kullanıcı bir işlemi iptal etmek veya durdurmak istediğinde.",
            actionType: "stop",
            example: "[ACTION: {\"type\": \"stop\"}]",
            requiresApproval: true
        )
    ]

    /// Sistem promptuna enjekte edilecek "YETENEKLERİM" bloğu.
    /// Ajanın hangi aracı ne zaman kullanacağını net biçimde öğretir.
    nonisolated static func promptBlock() -> String {
        let lines = all.map { capability in
            "- **\(capability.displayName)** (`\(capability.actionType)`): \(capability.summary)\n" +
            "  Kullan: \(capability.whenToUse)\n" +
            "  Örnek: \(capability.example)"
        }

        return """
        [MY CAPABILITIES — BU YETENEKLERİ KENDİN KULLAN]
        Sen bir asistansın; aşağıdaki araçlara gerçekten erişimin var. Kullanıcı isteğini
        karşılamak için hangisinin uygun olduğuna SEN karar ver. Bir aracı kullanırken tek
        bir [ACTION: {...}] etiketi çıkar; araç sonucunu bekleme, sonucu kullanıcıya
        doğal dille aktar.

        \(lines.joined(separator: "\n"))

        KARAR REHBERİ:
        - Güncel/doğrulanmamış bilgi → web_search
        - Dosya/klasör/kod içeriği → file
        - Güvenli terminal çıktısı → shell (ASLA rm, sudo, dd, curl|sh KULLANMA)
        - Uygulama/masaüstü/OS davranışı → applescript
        - Ekrandaki görsel inceleme → screenshot / computer_ocr
        - Sesli giriş → audio
        - Pano içeriği → clipboard
        - Sistem kaynakları → system_status
        - Uygulama içinde tıklama/yazma/kaydırma → computer_status, computer_list, computer_snapshot, computer_click,
          computer_type, computer_press, computer_scroll, computer_ocr, computer_clicktext,
          computer_launch, computer_clicklabel, computer_inspect, computer_interact, computer_drag,
          computer_setvalue, computer_fill, computer_submit, computer_wait
        - TARAYICI DOM KONTROLÜ (native hız) → browser_navigate, browser_fill, browser_click, browser_audit.
          Web formunda AX/OCR yerine bunları tercih et: bir kez browser_navigate ile sayfayı aç,
          browser_audit ile alanları gör, browser_fill ile doldur, browser_click ile gönder.
        - İptal/durdurma → stop

        COMPUTER USE DÖNGÜSÜ (observasyon → eylem → doğrulama):
        1. Önce `computer_status` ile izinleri kontrol et: Erişilebilirlik/Ekran
           Kaydı eksikse kullanıcıya hangi ayarı açması gerektiğini söyle.
        2. HEDEF SEÇİMİ (uygulama-bağımsız): Ajan pid vermek zorunda DEĞİLDİR.
           - "app": "Chrome" gibi bir uygulama adı verebilir.
           - pid/app yoksa otomatik olarak ÖN PLANDAKİ uygulama hedeflenir
             (herhangi bir uygulama: tarayıcı, form, yerel app — fark etmez).
           - Açık değilse `computer_launch` ile başlat.
        3. `computer_snapshot` ile etkileşimli öğeleri ve koordinatları al.
        4. Öğeyi metniyle hedefle: önce `computer_inspect` ile HEDEFİ KONTROL ET
           (güven %kaç? çok eşleşme var mı? disabled/offscreen mi?), sonra
           `computer_clicklabel` ile tıkla. Belirsizse körlemesine tıklama.
        5. Bir alana yazıp Enter'a basmak için tek çağrıda birleştir:
           `computer_interact` (click + type + pressKey). Ayrı çağrı yapma.
        6. TARAYICI/WEBVIEW: Chrome/Safari/Electron web girdileri AX'e "başarı"
           yalanı söyleyebilir (onChange tetiklenmez). Yazı yazarken `computer_type`
           (CGEvent) kullan; alanı doldurup göndermek için önce alana tıkla,
           sonra `computer_type`, sonra `computer_press` ("return") veya
           `computer_setvalue` ile değeri doğrudan yaz.
        7. Dönüşte "Doğrulama"da **değişiklik var mı** bak; yoksa farklı öğe
           veya bir sonraki kademe dene.
        8. AX ağacı boş/eksikse (canvas/oyun/bazı Electron) `computer_ocr` +
           `computer_clicktext` ile metne tıkla.
        9. Web formu doldururken alanı etiketiyle doldur: `computer_fill`
           (index yerine etiket; tarayıcıda indeksler kararsız olabilir).
        10. Yazma sessizce başarısız olduysa `computer_setvalue` ile AXValue yaz;
           UI'ın yüklenmesini beklemen gerekiyorsa `computer_wait` kullan.
        11. Tarayıcı formunda SUBMIT için `computer_submit` kullan — motor önce
           butona OCR ile tıklar, çalışmazsa otomatik klavye Tab+Return'a geçer.
        12. Web formunda NATİVE HIZ istiyorsan CDP kullan: `browser_navigate` ile
           sayfayı aç, `browser_audit` ile alan gör, `browser_fill` ile alanı doldur,
           `browser_click` ile gönder. Bu yol AX/OCR'den çok daha hızlı ve kesindir.

        KURAL: Yalnızca gerçekten gerekliyse araç kullan. Soru sadece bilgi istiyorsa ve
        arama gerekmiyorsa arama yapma. Kullanıcı görmek istediği bir işlemi açıkça
        istiyorsa araç kullan. Gizli/tehlikeli komut yazma. Güvensizsen güvenli cevap ver.

        ONAY AYRIMI:
        - Bilgi araçları (web_search, file-read, shell salt-okunur, screenshot, audio,
          clipboard, system_status) HER ZAMAN serbesttir; çekinmeden kullan.
        - Mutasyon araçları (yazma/silme/taşıma, uygulama kontrolü, stop) ONLAY GEREKTİRİR;
          bu durumda kullanıcıya önce ne yapacağını söyle ve onayını bekle.
        - Bir bilgi aracıyla kullanıcının istediği sonuca ulaşabilirsen mutasyona geçme.
        """
    }
}

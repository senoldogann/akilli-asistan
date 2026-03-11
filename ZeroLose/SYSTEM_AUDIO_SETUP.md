# System Audio Monitoring Kurulum Rehberi

> **Not:** Bilgisayardan gelen sesleri (mülakatçının sesi, sistem müzikleri vb.) ZeroLose'a aktarmak için iki yönteminiz bulunmaktadır.

## Yöntem 1: Native "No-Echo" Mode (Önerilen)

ZeroLose v1.1.0+ sürümü, macOS 12.3 ve üzeri sürümlerde herhangi bir ek yazılım (BlackHole vb.) gerektirmeden sistem sesini yakalayabilir.

1. **ZeroLose Settings** açın.
2. **Features** bölümüne gidin.
3. **No-Echo Mode** anahtarını açın (Subtitle: `🔊 Mic + Digital Meeting Capture`).
4. Bu modda sistem sesleri dijital olarak yakalanır ve mikrofonunuzla yankı yapmadan birleştirilir.

---

## Yöntem 2: BlackHole ile Manuel Kurulum (Eski Sistemler İçin)

Native mod çalışmıyorsa veya legacy bir kurulum istiyorsanız:

### 1. BlackHole Yükle
Eğer indirdiyseniz (2ch veya 16ch fark etmez) kurun. Homebrew ile:
```bash
brew install blackhole-2ch  # Veya blackhole-16ch
```

### 2. "Çok Çıkışlı Aygıt" (Multi-Output Device) Oluştur

Bu ayar, sesi hem duyabilmenizi hem de BlackHole'a (asistana) göndermenizi sağlar.

1. **Ses MIDI Kurulumu** (Audio MIDI Setup) uygulamasını açın.
2. Sol alttaki **+** butonuna basın ve **Çok Çıkışlı Aygıt Yarat** seçeneğini seçin.
3. Sağ paneldeki listeden şunları işaretleyin:
   - ✅ **Dahili Hoparlör** (Veya kullandığınız kulaklık/çıkış cihazı)
   - ✅ **BlackHole 2ch** (Veya 16ch)
4. Bu aygıtın ismini "ZeroLose Session" olarak değiştirebilirsiniz (Opsiyonel).
5. **Önemli:** Master Aygıt olarak **Dahili Hoparlör** seçili olduğundan ve "Sürüklenme Düzeltme" (Drift Correction) ayarının BlackHole için açık olduğundan emin olun.

### 3. Sistem Ses Çıkışını Ayarla

1. **Sistem Ayarları** → **Ses** → **Çıkış** sekmesine gidin.
2. Çıkış cihazı olarak yeni oluşturduğunuz **Çok Çıkışlı Aygıt**'ı seçin.

---

## Neden No-Echo?

- **Performans**: Native macOS API'si (ScreenCaptureKit) daha az gecikme sağlar.
- **Yankı Önleme**: Sistem sesi dijital olarak yakalandığı için mikrofona geri dönmez.
- **Kolaylık**: Ek aygıt kurulumu ve sistem çıkışı değiştirme zahmetinden kurtarır.

---

## Sorun Giderme

**Q: Ses gelmiyor?**
- Çok Çıkışlı Aygıt içindeki Master Device'ın doğru hoparlör olduğundan emin olun.
- Sistem ses düzeyini kontrol edin.

**Q: ZeroLose ses yakalamıyor?**
- ZeroLose ayarlarından "No-Echo" modunun doğru seçildiğinden emin olun.
- Sistem Ayarları'nda "Ekran Kaydı" ve "Erişilebilirlik" izinlerini kontrol edin.

**Versiyon:** 1.2.0 (Native Capture Integrated)

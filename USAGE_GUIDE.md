# 🚀 USAGE GUIDE: Maestro Sistemi Nasıl Kullanılır?

Bu sistem, senin için kod yazan sıradan bir AI değil; kurallara sıkı sıkıya bağlı bir **Yazılım Mühendisidir**. 
Onu bir "Junior Developer" gibi değil, bir "Takım Arkadaşı" gibi yönetmelisin.

---

## 🟢 Adım 1: Görevi Başlat (Tetikleyici)
Her iş için özel bir komut var. İsteğini yazmadan önce mutlaka bunları kullan:

| Komut | Ne Zaman Kullanılır? | Örnek |
|-------|----------------------|-------|
| `/brainstorm` | Fikrin henüz tam değilse, tartışmak istiyorsan. | *"Müzik uygulaması için veritabanı ne olmalı?"* |
| `/plan` | Ne yapacağını biliyorsun ama adım adım plan lazım. | *"Login sisteminin kurulum planını hazırla."* |
| `/create` | Yeni bir dosya, fonksiyon veya özellik eklenecekse. | *"User modelini oluştur ve API endpoint'i yaz."* |
| `/enhance` | Var olan bir koda özellik ekleyeceksen. | *"Login sistemine 'Google ile Giriş' ekle."* |
| `/debug` | Bir hata veya sorun varsa. | *"Uygulama 500 hatası veriyor, sebebi bul."* |
| `/test` | Test yazmak veya çalıştırmak için. | *"Auth servisi için unit testleri yaz."* |

---

## 🟡 Adım 2: Sokratik Kapı (Durdur & Düşün)
Komutu verdikten sonra ben hemen koda "saldırmam". Seni durdurur ve soru sorarım.
*   **Benim Amacım:** Hata yapma riskini sıfıra indirmek.
*   **Senin Görevin:** Sorularıma kısa ve net cevaplar vermek.

> *Örnek:* 
> **Ben:** "Veritabanı ilişkisel mi olacak? Hangi kütüphaneyi kullanacağız?"
> **Sen:** "PostgreSQL ve Prisma kullan."

---

## 🔵 Adım 3: Plan ve Onay (Implementation Plan)
Cevaplarını aldıktan sonra sana bir **Yol Haritası (Implementation Plan)** sunarım.
*   Bu dosyada hangi dosyaların değişeceği yazar.
*   Sen **"Onaylıyorum"** demeden tek satır kod yazmam.

---

## 🔴 Adım 4: İş Teslimi ve Kontrol (Verification)
Ben "İş bitti" dediğimde bana güvenme. Şu komutla beni denetle:

> **"Son kontrolleri yap ve raporu göster."**

Eğer terminalde **YEŞİL** onayları (✓) görmüyorsan, iş bitmemiş demektir. Düzeltmemi iste.

---

## 💡 İpuçları (Cheat Sheet)
*   **Kısa Ol:** Uzun destanlar yazmana gerek yok. `/create Login sayfası` demen yeterli. Detayları ben soracağım.
*   **Kuralcı Ol:** Eğer kurallara uymadığımı hissedersen (örn: test yazmadım), beni uyar: *"Kuralları oku!"*
*   **Dosya Yolları:** Bana dosyadan bahsederken tam yolunu söylemek zorunda değilsin, ama dosya adını doğru yaz.

**Hazırsan `/brainstorm` veya `/create` ile ilk görevini ver!** 🚀

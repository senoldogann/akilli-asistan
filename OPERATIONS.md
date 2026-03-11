# OPERATIONS.md (Usage Guide)

Bu projenin profesyonel altyapısını (Skills & Rules) en verimli şekilde nasıl kullanacağınızı anlatan en sade rehberdir.

## 1. Sistemin Çalışma Prensibi
Sistem iki ana koldan beslenir:
-   **Kurallar (`.agent/rules/`):** Benim (AI) anayasamdır. Nasıl davranacağımı, neyi yapmayacağımı söyler (Örn: Hata gizleme, test yazmadan geçme).
-   **Yetenekler (`.agent/skills/`):** Benim uzmanlık alanımdır. Bir konuyu (Örn: Docker, SEO, React) nasıl en iyi şekilde yapacağımı bana öğretir.

## 2. Bir Özelliği Nasıl Geliştirmeliyiz? (Standard Workflow)

Yeni bir koda başlamak istediğinizde şu komutu vermeniz yeterlidir:
> "Yeni bir özellik eklemek istiyorum: [Özellik Detayı]. Lütfen **feature-dev** workflow'unu takip et."

Ben otomatik olarak şu adımları izlerim:
1.  **Gereksinim Analizi:** Size 3 kritik soru sorarım.
2.  **ADR Kaydı:** Tasarım özetini `docs/adr/` altına yazarım.
3.  **TDD:** Önce testi yazar, sonra kodu geliştiririm.
4.  **Self-Reflection:** Bitirmeden önce kendimi eleştirir ve riskleri kontrol ederim.

## 3. Güvenlik Denetimi Nasıl Yapılır?
Herhangi bir aşamada şunu diyebilirsiniz:
> "Sistemi güvenlik açısından tara. **security-audit** workflow'unu kullan."

Ben o an 50+ siber güvenlik yeteneğimi (SQLMap, OWASP, Metasploit vb.) devreye sokar ve kodu cerrah titizliğiyle incelerim.

## 4. Dosya Yapısı (Connectivity)
-   **`AGENTS.md`**: Projenin kalbidir. Sistemin o anki durumunu buradan okurum.
-   **`.agent/rules/rules.md`**: Aktif kuralların listesidir.
-   **`.agent/skills/skills_index.json`**: Benim yetenekleri hızlıca bulmamı sağlayan rehberdir.

---
> [!TIP]
> Bir şeyi nasıl yapacağınızı sormayın, sadece ne yapmak istediğinizi söyleyin. Sistem geri kalanını kurallara ve yeteneklere göre otomatik halledecektir.

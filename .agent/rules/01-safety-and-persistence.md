# 🛡️ SAFETY & PERSISTENCE PROTOCOL

> **Principle:** "Infrastructure is permanent. Projects are transient. Never delete the brain."

## 1. PROTECTED ENTITIES
Aşağıdaki dosya ve klasörler **KUTSALDIR**. Hiçbir koşulda silinemez, üzerine yazılamamaz veya taşınamaz (kullanıcı açıkça komut vermedikçe):
- `.agent/` (Tüm içerik: rules, skills, templates, workflows)
- `AGENTS.md`
- `OPERATIONS.md`
- `docs/adr/`

## 2. SAFE INITIALIZATION PATTERN
Eğer `create-next-app`, `npx create-react-app` veya benzeri "boş dizin isteyen" bir komut çalıştırılacaksa:

1.  **PRE-CHECK:** Ana dizindeki mevcut dosyaları kontrol et.
2.  **BACKUP (Don't Delete):** Eğer dizin doluysa, mevcut dosyaları asla silme! Şunları yap:
    - Yeni bir alt klasör oluştur (Örn: `app/` veya `frontend/`).
    - VEYA, mevcut dosyaları geçici bir `.backup_init_[timestamp]/` klasörüne taşı.
3.  **ISOLATION:** Komutu bu alt klasörde çalıştır veya ana dizinde çalıştıracaksan `--ignore-existing` (varsa) parametresini kullan.

## 3. ANTI-DESTRUCTION RULES
- **NO `rm -rf *`:** Ana dizinde asla yıldız işaretiyle toplu silme yapma.
- **PROMPT BEFORE OVERWRITE:** Mevcut bir dosyanın üzerine yazmadan önce mutlaka kullanıcıdan onay al.
- **ATOMIC ACTIONS:** Bir proje kurulumu yarıda kalırsa, altyapı dosyalarının ( `.agent` ) hala yerinde olduğundan emin ol.

## 4. EMERGENCY RECOVERY
Eğer yanlışlıkla bir altyapı dosyası silinirse, derhal dur ve `brain/` üzerindeki yedeklerden (eğer varsa) veya en son state'den geri yükleme yapmaya çalış.

---
trigger: always_on
---

# 50 - SECURITY & TESTING PROTOCOL

> **Principle:** "Security is not a feature; it is the foundation. Tests are the evidence of truth."

## 1. THE SECURITY GATEKEEPER
Her değişiklik minimum şu güvenlik kapılarından geçmelidir:
1. **Secrets / PII:** Email, şifre, token, anahtar, kart bilgisi veya hassas tanımlayıcı loglanmaz ve hardcode edilmez.
2. **Validation:** Tüm dış girdiler kirli kabul edilir; parse, validate ve normalize edilmeden kullanılmaz.
3. **AuthN/AuthZ:** Yetkili işlem yapan her yol için authentication ve authorization açıkça testlenir.
4. **Dependencies:** Yeni paket eklenmeden önce bakım durumu, güvenlik geçmişi ve audit sonucu kontrol edilir.

## 2. TEST MATRIX (MANDATORY)
Test yazılmamış kod tamamlanmış sayılmaz.
- **Unit Tests:** Branching, dönüşüm, kural, hesaplama ve edge-case içeren logic için zorunlu.
- **Integration Tests:** Veritabanı, queue, cache, filesystem, auth boundary ve external API adaptörleri için zorunlu.
- **E2E Tests:** Login, signup, checkout, publish, upgrade, payment, destructive actions veya iş açısından kritik akışlar için zorunlu.
- **Regression Tests:** Bug fix veya davranış değişikliği varsa regresyon testi zorunlu.

## 3. EDGE-CASE CHECKLIST
Şunlar relevant ise testlenmeden iş complete sayılamaz:
- boş, null, whitespace, malformed input
- min/max sınırlar, taşma, çok büyük payload
- duplicate submit, retry, replay, race condition
- pagination first/last/invalid cursor
- timezone, locale, currency, serialization farkları
- upstream timeout, partial failure, offline veya degraded mode
- permission boundary ve tenant isolation

## 4. RELEASE BLOCKERS
- Başarısız test, lint veya security scan varsa iş tamamlanmış sayılmaz.
- Kritik kullanıcı yolu için e2e yoksa iş tamamlanmış sayılmaz; kullanıcı açıkça waive etmelidir.
- Negatif test olmadan yalnızca happy-path coverage yeterli değildir.
- Test kanıtı olmadan "fixed", "done", "working" veya "production-ready" denemez.

## 5. COMPLIANCE & BEST PRACTICES
- **OWASP Top 10:** SQL Injection, XSS, CSRF, broken access control ve auth zafiyetleri aktif checklist olarak ele alınır.
- **Least Privilege:** Sistem, servis hesabı ve token izinleri minimum yetkiyle kurulur.
- **Secrets Management:** `.env.example` güncel tutulur; gerçek secret repo'ya girmez.
- **Performance Safety:** N+1 query, full-table scan, unbounded list, synchronous heavy work ve cache-stampede riskleri kontrol edilir.

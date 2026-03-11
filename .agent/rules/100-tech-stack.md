# 🎯 TECH STACK RULES: Maestro Rules & Scripts

> **CONTEXT:** Bu repo bir uygulama değil; çok sağlayıcılı ajan kural setleri, adapter konfigürasyonları ve doğrulama scriptleri üretir.

## 1. CANONICAL STACK
* **Primary Artifacts:** Markdown (`.md`), TOML (`.toml`), JSON (`.json`) ve Python (`.py`).
* **Runtime Target:** Scriptler ek bağımlılık gerektirmeden `python3` ile çalışmalıdır.
* **Filesystem Contract:** Sağlayıcı adapterları mümkün olan yerde symlink ile paylaşılmalı, metin kopyası üretilmemelidir.
* **Source Of Truth:** Politik metinler `AGENTS.md` ve `.agent/` altında yaşar; provider adapterları yalnızca uyarlama katmanıdır.

## 2. PYTHON SCRIPT RULES
* **Standard Library First:** `scripts/` altında standart kütüphane dışı bağımlılık ekleme.
* **Deterministic Output:** `sync_agents.py` aynı girdide aynı dosyaları üretmelidir.
* **Safe File Ops:** Scriptler yalnızca bu reponun beklenen adapter yollarını yazmalı veya silmelidir.
* **Explicit Failure:** Beklenmeyen durumlar sessizce yutulmaz; hata görünür biçimde yükseltilir.

## 3. CONFIGURATION RULES
* **Official Keys Only:** `.codex/config.toml`, `.claude/settings.json` ve `opencode.json` içinde yalnızca resmi dökümantasyonda geçen alanlar kullanılmalıdır.
* **Provider Isolation:** Bir sağlayıcıya ait ayar başka bir sağlayıcının dosyasına taşınmaz.
* **No Secret Material:** Repo içine token, API key, local credential veya kişisel path hardcode edilmez.
* **Human Reviewable:** JSON/TOML dosyaları okunabilir, küçük ve diff dostu tutulmalıdır.

## 4. CHANGE WORKFLOW
* **Rule Change => Sync:** Her adapter, kural veya provider config değişikliğinden sonra `python3 scripts/sync_agents.py` çalıştırılır.
* **Completion Gate:** Tamamlama öncesi `python3 scripts/verify_all.py` zorunludur.
* **Drift Zero:** Elle yapılan provider değişiklikleri `sync_agents.py` içine geri taşınmadan bırakılmaz.

## 5. ARCHITECTURE & DELIVERY GATES
* **Architecture First:** Uygulama türü ne olursa olsun modül sınırları, dependency direction, veri sahipliği ve failure mode'lar implementation öncesi netleşmelidir.
* **Security By Default:** Auth, validation, secret handling ve least-privilege tasarımı sonradan eklenen katman değil, başlangıç kararıdır.
* **Performance By Design:** Unbounded iteration, N+1, eager loading, büyük payload ve gereksiz sync I/O riskleri önceden kontrol edilmelidir.
* **Test Pyramid:** Relevant olduğu yerde unit + integration + e2e birlikte düşünülmeli; kritik yol sadece unit test ile kapatılmış sayılmaz.
* **Edge Cases Are Part Of Scope:** Null, empty, limits, concurrency, retries, locale/timezone ve permission boundary senaryoları "nice to have" değildir.

## 6. FORBIDDEN PATTERNS
* **No Unofficial Mirrors:** Resmi provider özelliği değilse repo yapısında native gibi sunulmaz.
* **No Duplicate Policy Blobs:** Aynı kural metni farklı provider dosyalarına kopyalanmaz.
* **No Broad Permissions By Default:** Claude Code ve OpenCode izinleri gerekli en dar kapsamla tanımlanır.
* **No Guesswork:** Config anahtarı, command dizini veya permission sözdizimi doğrulanmadan eklenmez.

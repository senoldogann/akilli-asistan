---
trigger: always_on
---

# 🛡️ ERROR HANDLING & RESILIENCE PATTERNS

> **Principle:** "No silent failures. Every error must be caught, logged, and handled gracefully."

## 1. LANGUAGE-SPECIFIC PATTERNS

### TypeScript / JavaScript
```typescript
// ❌ YASAK: Boş catch bloğu
try {
  await riskyOperation();
} catch (e) {
  // Sessiz hata - YASAK
}

// ✅ DOĞRU: Hata logla ve yeniden fırlat veya handle et
try {
  await riskyOperation();
} catch (error) {
  logger.error('Operation failed', { error, context: 'riskyOperation' });
  throw new AppError('OPERATION_FAILED', error.message, { cause: error });
}
```

### Go
```go
// ❌ YASAK: Hata yok sayma
result, _ := SomeFunction()

// ✅ DOĞRU: Her hatayı kontrol et
result, err := SomeFunction()
if err != nil {
    return fmt.Errorf("SomeFunction failed: %w", err)
}
```

### Python
```python
# ❌ YASAK: Bare except
try:
    risky_operation()
except:
    pass

# ✅ DOĞRU: Spesifik exception ve loglama
try:
    risky_operation()
except ValidationError as e:
    logger.warning(f"Validation failed: {e}")
    raise
except Exception as e:
    logger.error(f"Unexpected error: {e}", exc_info=True)
    raise AppError("OPERATION_FAILED") from e
```

### Rust
```rust
// ❌ YASAK: unwrap() production kodunda
let value = some_option.unwrap();

// ✅ DOĞRU: Result<T, E> veya Option<T> ile handle et
let value = some_option.ok_or_else(|| AppError::NotFound("Value missing"))?;
```

## 2. ERROR RESPONSE FORMAT (API)
Tüm API'ler RFC 7807 (Problem Details) formatını kullanmalı:

```json
{
  "type": "https://api.example.com/errors/validation",
  "title": "Validation Error",
  "status": 400,
  "detail": "The 'email' field must be a valid email address.",
  "instance": "/users/123",
  "timestamp": "2024-01-15T10:30:00Z",
  "traceId": "abc-123-def"
}
```

## 3. RETRY PATTERNS

### Exponential Backoff with Jitter
```typescript
async function withRetry<T>(
  fn: () => Promise<T>,
  maxAttempts = 3,
  baseDelayMs = 1000
): Promise<T> {
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (error) {
      if (attempt === maxAttempts) throw error;
      
      const delay = baseDelayMs * Math.pow(2, attempt - 1);
      const jitter = Math.random() * delay * 0.1;
      await sleep(delay + jitter);
    }
  }
}
```

## 4. CIRCUIT BREAKER PATTERN
Dış servislere yapılan çağrılarda Circuit Breaker kullan:

| State | Davranış |
|-------|----------|
| **CLOSED** | Normal çalışma, hatalar sayılıyor |
| **OPEN** | Tüm çağrılar anında başarısız (fail-fast) |
| **HALF-OPEN** | Test çağrısı yapılır, başarılıysa CLOSED'a geç |

## 5. GRACEFUL DEGRADATION
Bir servis başarısız olduğunda:
1. **Cache'den Dön:** Eski veri, hiç veri olmamasından iyidir.
2. **Default Değer:** Güvenli bir varsayılan dön.
3. **Feature Disable:** İlgili özelliği geçici olarak kapat.

## 6. FAILURE-MODE CHECKLIST
Her boundary için şu sorular implementation öncesi cevaplanmalıdır:
- Timeout süresi nedir?
- Retry yapılacak mı, yapılacaksa hangi hatalarda ve kaç kez?
- İşlem idempotent mi?
- Partial failure durumunda veri tutarlılığı nasıl korunacak?
- Kullanıcı ne görecek, monitoring ne alacak, ne alarm üretecek?
- Bu başarısız yol unit/integration test ile doğrulandı mı?

## 7. EXTERNAL CALL CONTRACT
- Her dış servis çağrısı explicit timeout taşımalıdır.
- Retry politikası yazılı olmalı; default retry yokmuş gibi davran.
- Circuit breaker veya fail-fast stratejisi olmayan kritik upstream bağımlılık kabul edilmez.
- Hata sınıflandırması yapılmalı: kullanıcı hatası, geçici upstream hatası, kalıcı sistem hatası.

## 8. MANDATORY PRACTICES
- [ ] Her async fonksiyon try-catch içermeli
- [ ] Her hata bir `traceId` ile loglanmalı
- [ ] Kullanıcıya gösterilen hata mesajları teknik detay içermemeli
- [ ] 5xx hatalar monitoring'e alarm olarak düşmeli
- [ ] Her dış çağrıda timeout, retry kararı ve failure testi açık olmalı

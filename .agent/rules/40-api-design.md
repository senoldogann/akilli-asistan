---
trigger: always_on
---

# 🌐 API DESIGN STANDARDS

> **Principle:** "API is a contract. Once published, it cannot be broken."

## 1. REST CONVENTIONS

### Contract Before Code
Bir endpoint yazılmadan önce şu kararlar net olmalıdır:
- Resource ownership ve sınırlar
- Authentication / authorization kuralı
- Idempotency davranışı
- Pagination veya streaming ihtiyacı
- Beklenen hata sınıfları ve status code'lar
- Latency ve payload boyutu açısından performans riski
- Backward-compatibility ve versiyonlama etkisi

### HTTP Methods
| Method | Kullanım | Idempotent | Safe |
|--------|----------|------------|------|
| `GET` | Kaynak oku | ✅ | ✅ |
| `POST` | Yeni kaynak oluştur | ❌ | ❌ |
| `PUT` | Kaynağı tamamen değiştir | ✅ | ❌ |
| `PATCH` | Kaynağı kısmi güncelle | ❌ | ❌ |
| `DELETE` | Kaynağı sil | ✅ | ❌ |

### URL Naming
```
✅ DOĞRU:
GET    /api/v1/users
GET    /api/v1/users/{id}
GET    /api/v1/users/{id}/orders
POST   /api/v1/users
PATCH  /api/v1/users/{id}
DELETE /api/v1/users/{id}

❌ YANLIŞ:
GET    /api/getUsers
POST   /api/createUser
GET    /api/user_orders
```

### Query Parameters
```
# Filtreleme
GET /api/v1/products?category=electronics&minPrice=100

# Sayfalama (Cursor-based tercih edilir)
GET /api/v1/products?cursor=abc123&limit=20

# Sıralama
GET /api/v1/products?sort=-createdAt,name

# Alan Seçimi (Sparse Fieldsets)
GET /api/v1/products?fields=id,name,price
```

## 2. VERSIONING STRATEGY

### URL-Based Versioning (Önerilen)
```
/api/v1/users
/api/v2/users
```

### Deprecation Policy
1. Yeni versiyon çıktığında, eski versiyon **minimum 6 ay** desteklenmeli.
2. Deprecation header'ı ekle: `Deprecation: true`
3. Sunset header'ı ekle: `Sunset: Sat, 01 Jan 2025 00:00:00 GMT`

## 3. RESPONSE FORMAT

### Success Response
```json
{
  "data": {
    "id": "user_123",
    "email": "user@example.com",
    "createdAt": "2024-01-15T10:30:00Z"
  },
  "meta": {
    "requestId": "req_abc123"
  }
}
```

### Collection Response (Paginated)
```json
{
  "data": [...],
  "meta": {
    "total": 150,
    "page": 2,
    "perPage": 20,
    "hasMore": true
  },
  "links": {
    "self": "/api/v1/users?page=2",
    "next": "/api/v1/users?page=3",
    "prev": "/api/v1/users?page=1"
  }
}
```

### Error Response (RFC 7807)
```json
{
  "type": "https://api.example.com/errors/validation",
  "title": "Validation Error",
  "status": 400,
  "detail": "The 'email' field is required.",
  "instance": "/api/v1/users",
  "errors": [
    {
      "field": "email",
      "code": "REQUIRED",
      "message": "Email is required"
    }
  ]
}
```

### Data Types (The Time & Money Trap)

> **Uyarı:** Tarih ve para birimi formatı en büyük API kaos kaynaklarıdır.

**Dates:** MUST use ISO 8601 format in UTC.
```
✅ "2024-01-15T10:30:00Z"
❌ "15/01/2024"            (Ambiguous - US vs EU)
❌ "2024-01-15 10:30:00"   (No timezone = disaster)
❌ 1705312200              (Unix timestamp - debugging nightmare)
```

**Currency:** MUST use smallest unit (cents) or string to avoid floating point errors.
```json
// ✅ DOĞRU: Cents (integer)
{ "amount": 1000, "currency": "USD" }  // = $10.00

// ✅ DOĞRU: String (for precision)
{ "amount": "10.00", "currency": "USD" }

// ❌ YANLIŞ: Float (0.1 + 0.2 = 0.30000000000000004)
{ "amount": 10.00, "currency": "USD" }
```

**UUIDs:** Prefer prefixed IDs for debugging.
```
✅ "user_a1b2c3d4-e5f6-7890-abcd-ef1234567890"
✅ "order_123e4567-e89b-12d3-a456-426614174000"
❌ "a1b2c3d4-e5f6-7890-abcd-ef1234567890"  (What is this?)
```

## 4. HTTP STATUS CODES

### Success (2xx)
| Code | Kullanım |
|------|----------|
| `200` | GET, PATCH, DELETE başarılı |
| `201` | POST ile kaynak oluşturuldu |
| `204` | Başarılı ama içerik yok |

### Client Error (4xx)
| Code | Kullanım |
|------|----------|
| `400` | Geçersiz request body/params |
| `401` | Authentication gerekli |
| `403` | Yetkisiz erişim |
| `404` | Kaynak bulunamadı |
| `409` | Conflict (duplicate, race condition) |
| `422` | Validation hatası |
| `429` | Rate limit aşıldı |

### Server Error (5xx)
| Code | Kullanım |
|------|----------|
| `500` | Beklenmeyen sunucu hatası |
| `502` | Upstream servis hatası |
| `503` | Servis geçici olarak kullanılamıyor |
| `504` | Upstream timeout |

## 5. RATE LIMITING

### Headers
```
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 45
X-RateLimit-Reset: 1705312200
Retry-After: 60
```

### Strategy
- **Anonymous:** 60 req/min
- **Authenticated:** 1000 req/min
- **Premium:** 10000 req/min

### 429 Response
```json
{
  "type": "https://api.example.com/errors/rate-limit",
  "title": "Rate Limit Exceeded",
  "status": 429,
  "detail": "You have exceeded 100 requests per minute.",
  "retryAfter": 45
}
```

## 6. SECURITY HEADERS

Her API response'unda şu header'lar olmalı:
```
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
X-XSS-Protection: 1; mode=block
Strict-Transport-Security: max-age=31536000; includeSubDomains
Content-Security-Policy: default-src 'self'
```

## 7. MANDATORY ENDPOINTS

Her API şunlara sahip olmalı:
```
GET  /health          → { "status": "healthy" }
GET  /health/ready    → { "status": "ready", "checks": {...} }
GET  /health/live     → { "status": "alive" }
GET  /api/v1/openapi  → OpenAPI 3.0 spec (JSON)
```

## 8. TESTED CONTRACT
- Her public endpoint için success path yanında invalid input, unauthorized/forbidden, not-found, conflict ve upstream-failure senaryoları testlenmelidir.
- Cursor, pagination, filtering, sorting ve sparse fieldset davranışı testle ispatlanmalıdır.
- Kritik kullanıcı akışları sadece endpoint testleriyle değil, en az bir e2e akışla doğrulanmalıdır.

## 8. DOCUMENTATION

- OpenAPI 3.0 spec **zorunlu**
- Her endpoint için örnek request/response
- Authentication açıklaması
- Rate limit bilgisi
- Changelog (breaking changes vurgulu)

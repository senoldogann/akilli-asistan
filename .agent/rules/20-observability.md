---
trigger: always_on
---

# RULE: OBSERVABILITY & LOGGING STANDARD

> **Principle:** "If you can't measure it, you can't manage it."

1.  **NO Console Logs:** Production kodunda `console.log` yasaktır. Yapılandırılmış bir Logger (Winston, Pino, Zap, Logrus vb.) kullanılmalıdır.
2.  **Log Levels:**
    * `ERROR`: Sistem çalışmayı durdurduğunda (Alarm tetikler).
    * `WARN`: Sistem çalışıyor ama bir şeyler yanlış (Recoverable).
    * `INFO`: İşlem başarılı (Audit trail).
    * `DEBUG`: Sadece geliştirme ortamında görünür.
3.  **Tracing:** Her request bir `transaction_id` veya `request_id` taşımalıdır. Bu ID loglarda görünmelidir.
4.  **Health Check:** Her servis `/health` ve `/readiness` endpoint'lerine sahip olmalıdır.
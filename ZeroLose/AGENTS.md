# AGENTS.md

> **Bu Dosya Nedir?** Bu dosya, projenin "kimlik kartı"dır. LLM ajanları bu dosyayı okuyarak projenin bağlamını, kurallarını ve yapısını anlar.

## 📋 Proje Bilgileri

| Alan | Değer |
|------|-------|
| **Proje Adı** | ZeroLose (Stealth AI Agent) |
| **Versiyon** | 1.0.0 |
| **Proje Tipi** | macOS Desktop App (Stealth) |
| **Başlangıç Tarihi** | 2026-01-20 |

## 🎯 Proje Amacı

ZeroLose, mülakatlar ve toplantılar sırasında görünmez bir AI asistan olarak çalışan bir macOS masaüstü uygulamasıdır. Ekran paylaşımlarında (Zoom, Teams) görünmez kalır ve sesli soruları gerçek zamanlı olarak transkribe edip AI ile yanıtlar.

## 🛠️ Tech Stack

| Katman | Teknoloji | Versiyon |
|--------|-----------|----------|
| **Runtime** | Swift | 6.0 |
| **UI Framework** | SwiftUI + AppKit | macOS 14+ |
| **AI Backend** | Cloud API (DeepSeek, GPT, Gemini) | N/A |
| **Speech-to-Text** | Groq Whisper API | whisper-large-v3-turbo |
| **Web Search** | Tavily API | v1 |
| **Screen Capture** | ScreenCaptureKit | macOS Native |

## 📁 Dizin Yapısı

```
ZeroLose/
├── ZeroLose/
│   ├── ZeroLoseApp.swift      # Entry point
│   ├── Resources/             # Secrets, Constants
│   ├── Services/              # Core business logic
│   ├── ViewModels/            # UI state management
│   └── Views/                 # SwiftUI Views
└── ZeroLose.xcodeproj        # Xcode Project
```

## 🚫 Yasaklar (Katı Kurallar)

1. [x] `unwrap()` production kodunda yasak (Swift'te `guard let` veya `if let` kullanın)
2. [x] API key'ler hardcoded olmamalı (Secrets.swift kullanılıyor)
3. [x] `print()` debugging için kullanılabilir ama canlıda Logger kullanın
4. [x] `any` tipi yasak (Swift'te protocol kullanın)
5. [x] MainActor isolation ihlali yasak

## 🔐 Güvenlik Notları

- API key'ler `Secrets.swift` dosyasında tutulur (Prod'da Keychain önerilir)
- `NSWindow.sharingType = .none` ile ekran paylaşımından gizleniyor
- `LSUIElement = true` ile Dock'tan gizleniyor
- Ses verileri yalnızca geçici dosya olarak yazılır ve anında silinir

## 📞 İletişim

| Rol | Kişi |
|-----|------|
| **Tech Lead** | Dogan |
| **Proje Sahibi** | Dogan |

---

> ⚠️ **Ajan Notu:** Bu dosyayı düzenlerken `.agent/scripts/gatekeeper.sh` kontrollerinin geçtiğinden emin ol.

import Foundation
import AppKit
import os

/// Chrome DevTools Protocol (CDP) tabanlı native-hız tarayıcı kontrolü.
///
/// Neden CDP? Web formlarını AX/OCR ile doldurmak hem yavaş hem güvenilmez
/// (AX koordinatı web içeriğinde yanlış, Chromium CGEvent mouse'u yutuyor).
/// CDP, sayfanın DOM'una `Runtime.evaluate` ile DOĞRUDAN erişir: form alanı
/// doldurma <100ms, piksel/koordinat tahmini yok, native kesinlik.
///
/// Kullanım: Chrome'u `--remote-debugging-port` + geçici `--user-data-dir` ile
/// başlatır (varsayılan profille CDP engellenir), sayfa target'ına WebSocket
/// bağlar ve JSON-RPC mesajlarını id-bazlı eşleştirerek yanıtları toplar.
///
/// Güvenlik: Yalnızca localhost'a bağlanır; CDP yalnızca bu uygulamanın
/// başlattığı geçici profil üzerinde açılır. Hiçbir uzak adrese gitmez.
@MainActor
final class BrowserCDPService {
    private let logger = Logger(subsystem: "com.zerolose", category: "browsercdp")
    private var chromeProcess: Process?
    private var websocket: URLSessionWebSocketTask?
    private var nextId = 0
    private var activePageId: String?

    struct CDPError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum XOrCGFloat {
        case point(CGFloat, CGFloat)
    }

    /// CDP'ye bağlı bir Chrome başlatır (geçici profil + remote-debugging port).
    /// Sayfa hazır olduğunda döner; aksi hâlde hata verir.
    func launch(port: Int = 9333, url: String = "about:blank") async throws {
        if let chromeProcess, chromeProcess.isRunning {
            // Zaten bağlı: sayfayı istenen adrese götür.
            if let page = activePageId { _ = try? await evaluate("location.href='\(url)'", pageId: page) }
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        proc.arguments = [
            "--remote-debugging-port=\(port)",
            "--user-data-dir=/tmp/zerolose-cdp-profile",
            "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
            "--disable-component-update", "--no-sandbox", url
        ]
        do {
            try proc.run()
            chromeProcess = proc
        } catch {
            throw CDPError(message: "Chrome başlatılamadı: \(error.localizedDescription)")
        }

        // Port'un açılmasını bekle (poll).
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if pageTargetUrl(port: port) != nil {
                break
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let pageUrl = pageTargetUrl(port: port) else {
            throw CDPError(message: "CDP portu açılmadı (\(port)). Chrome başlatılamadı.")
        }
        try await connect(to: pageUrl)
        // Bağlantının gerçekten hazır olduğunu doğrulamak için bir Runtime.evaluate
        // ping'i gönder ve yanıt bekle. Böylece ilk çağrı "Socket not connected"
        // hatasına takılmaz.
        _ = try await evaluate("1+1")
        if url != "about:blank" {
            _ = try? await evaluate("location.href='\(url)'")
        }
        logger.info("🧭 Chrome CDP bağlandı (port \(port))")
    }

    /// CDP bağlantısını kapatır ve Chrome'u durdurur.
    func shutdown() {
        websocket?.cancel(with: .goingAway, reason: nil)
        websocket = nil
        chromeProcess?.terminate()
        chromeProcess = nil
        activePageId = nil
    }

    func isConnected() -> Bool {
        websocket != nil && activePageId != nil
    }

    // MARK: - DOM işlemleri

    /// Sayfayı adrese götürür ve yüklenmesini bekler.
    func navigate(url: String) async throws {
        _ = try await send("Page.navigate", params: ["url": url])
        try await Task.sleep(nanoseconds: 900_000_000)
    }

    /// Sayfadaki metni DOM seçicisiyle bulup tıklar.
    func click(selector: String) async throws -> String {
        let js = try await evaluateRaw("""
        (function(){
          var el = document.querySelector('\(selector)');
          if(!el) return 'NOT_FOUND';
          el.scrollIntoView({block:'center'});
          el.click();
          return 'CLICKED';
        })()
        """)
        let value = js["result"] as? [String: Any]
        let resultValue = value?["value"] as? String ?? "?"
        guard resultValue != "NOT_FOUND" else { throw CDPError(message: "DOM'da seçici bulunamadı: \(selector)") }
        return "clicked via CDP: \(selector)"
    }

    /// Bir form alanını DOM'da bulup değeri doğrudan yazar (native hız).
    func fillField(selector: String, value: String) async throws -> String {
        let escapedValue = Self.jsString(value)
        let js = try await evaluateRaw("""
        (function(){
          var el = document.querySelector('\(selector)');
          if(!el) return 'NOT_FOUND';
          el.focus();
          el.value = \(escapedValue);
          el.dispatchEvent(new Event('input', {bubbles:true}));
          el.dispatchEvent(new Event('change', {bubbles:true}));
          return 'FILLED';
        })()
        """)
        let resultValue = extractString(js)
        guard resultValue != "NOT_FOUND" else { throw CDPError(message: "DOM'da alan bulunamadı: \(selector)") }
        return "filled via CDP: \(selector)"
    }

    /// Sayfadaki bir veriyi DOM üzerinden okur (doğrulama).
    func readValue(selector: String) async throws -> String {
        let js = try await evaluateRaw("(document.querySelector('\(selector)')||{}).value || ''")
        return extractString(js)
    }

    /// Sayfada bir metnin görünüp görünmediğini DOM'dan sorgular.
    func textExists(_ text: String) async throws -> Bool {
        let js = try await evaluateRaw("document.body.innerText.includes(\(Self.jsString(text)))")
        return extractBool(js)
    }

    /// Sayfa DOM'unun okunabilir bir özetini döndürür (form alanları + butonlar).
    func auditPage() async throws -> String {
        let js = try await evaluateRaw("""
        (function(){
          var out=[];
          document.querySelectorAll('input,textarea,select,button,[role=button]').forEach(function(e,i){
            var t=(e.name||e.id||e.placeholder||e.textContent||'').trim();
            if(t) out.push('#'+i+' <'+e.tagName.toLowerCase()+'> '+t);
          });
          return out.slice(0,60).join('\\n');
        })()
        """)
        return extractString(js)
    }

    // MARK: - CDP düşük seviye

    private func evaluateRaw(_ expression: String) async throws -> [String: Any] {
        let params: [String: Any] = ["expression": expression, "returnByValue": true, "awaitPromise": true]
        let response = try await send("Runtime.evaluate", params: params)
        return response
    }

    private func evaluate(_ expression: String, pageId: String? = nil) async throws -> String {
        let params: [String: Any] = ["expression": expression, "returnByValue": true, "awaitPromise": true]
        let response = try await send("Runtime.evaluate", params: params)
        return extractString(response)
    }

    private func extractString(_ response: [String: Any]) -> String {
        if let result = response["result"] as? [String: Any],
           let value = result["value"] as? String { return value }
        if let result = response["result"] as? [String: Any],
           let value = result["value"] as? Bool { return value ? "true" : "false" }
        return ""
    }

    private func extractBool(_ response: [String: Any]) -> Bool {
        if let result = response["result"] as? [String: Any],
           let value = result["value"] as? Bool { return value }
        return false
    }

    /// Bir Swift String'ini JS'te güvenli bir string literal'ine çevirir
    /// (tırnak/backslash/control karakterlerini kaçışlayarak). `JSON.stringify`
    /// yerine tam SDK uyumlu yol.
    nonisolated private static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let arr = String(data: data, encoding: .utf8) ?? ""
        // JSON array => ilk elemanı döndür: ["..."] -> "..."
        if arr.hasPrefix("["), arr.hasSuffix("]") {
            return String(arr.dropFirst().dropLast())
        }
        return "\"\""
    }

    /// CDP'ye JSON-RPC komutu gönderir, aynı `id` ile yanıtı bekler.
    private func send(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        guard let websocket else { throw CDPError(message: "CDP bağlantısı yok. Önce launch() çağır.") }
        nextId += 1
        let id = nextId
        var body: [String: Any] = ["id": id, "method": method]
        if !params.isEmpty { body["params"] = params }
        let data = try JSONSerialization.data(withJSONObject: body)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            websocket.send(.data(data)) { err in
                if let err { cont.resume(throwing: err) } else { cont.resume(returning: ()) }
            }
        }
        // Sıralı kullanım için webSocket.receive() ile eşleşen id'yi bekleriz.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let response = try await receiveMessage(from: websocket)
            if let responseId = response["id"] as? Int, responseId == id {
                return response
            }
            // Eşleşmeyen id: atla (event vs).
            if response["method"] != nil { continue }
        }
        throw CDPError(message: "CDP yanıt zaman aşımı: \(method)")
    }

    /// WebSocket'ten tek bir JSON mesajı okur.
    private func receiveMessage(from ws: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await ws.receive()
        let text: String
        switch message {
        case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
        case .string(let s): text = s
        @unknown default: text = ""
        }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    /// WebSocket'e bağlanır.
    private func connect(to urlString: String) async throws {
        guard let url = URL(string: urlString) else { throw CDPError(message: "Geçersiz CDP URL: \(urlString)") }
        let ws = URLSession.shared.webSocketTask(with: url)
        websocket = ws
        ws.resume()
        activePageId = url.lastPathComponent
        // Kısa bir bekleme ile el sıkışmanın tamamlanmasını sağla.
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    /// Port üzerindeki ilk sayfa target'ının WebSocket URL'sini döndürür.
    private func pageTargetUrl(port: Int) -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/list"),
              let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let page = arr.first(where: { ($0["type"] as? String) == "page" }) else { return nil }
        return page["webSocketDebuggerUrl"] as? String
    }
}

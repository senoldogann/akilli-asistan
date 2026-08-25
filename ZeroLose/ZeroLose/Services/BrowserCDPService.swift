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
    private var bridgeProcess: Process?
    private var outputPipe: Pipe?
    private var inputPipe: Pipe?
    private let buffer = PipeLineBuffer()
    private var connected = false
    private var port = 9333
    private var bridgePath: String {
        // Repo içindeki köprünün mutlak yolu. App bundle'dan veya $PWD'den çöz.
        let candidates = [
            FileManager.default.currentDirectoryPath + "/tools/browser-cdp/bridge.mjs",
            "/Users/dogan/Desktop/akilli-asistan/tools/browser-cdp/bridge.mjs"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
            ?? candidates[0]
    }

    struct CDPError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum XOrCGFloat {
        case point(CGFloat, CGFloat)
    }

    /// CDP'ye bağlı bir Chrome başlatır; ardından Node köprüsünü (ws tabanlı CDP
    /// istemcisi) çalıştırır. URLSessionWebSocketTask Chrome CDP'de güvenilir
    /// çalışmadığı için bu köprü native-hız DOM kontrolünü sağlar.
    func launch(port: Int = 9333, url: String = "about:blank") async throws {
        if connected { return }
        self.port = port
        // Chrome'u CDP ile başlat.
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
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try await startBridge()
        _ = try await sendBridge("navigate", [url])
        logger.info("🧭 Chrome CDP köprüsü hazır (port \(port))")
    }

    /// Node köprüsünü (bridge.mjs) başlatır ve READY sinyalini bekler.
    private func startBridge() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["node", bridgePath, "\(port)"]
        let out = Pipe()
        let inp = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = inp
        do {
            try p.run()
        } catch {
            throw CDPError(message: "Node köprüsü başlatılamadı (\(error.localizedDescription)). 'tools/browser-cdp' altında npm install ws gerekli.")
        }
        bridgeProcess = p
        outputPipe = out
        inputPipe = inp
        // Pipe'tan gelen veriyi buffer'a biriktiren handler kur (bloklamaz).
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let d = handle.availableData
            if !d.isEmpty {
                self.buffer.append(d)
            }
        }
        let readyLine = try await readLineFromBuffer()
        guard readyLine.hasPrefix("READY") else {
            throw CDPError(message: "CDP köprüsü READY vermedi (Node ws yüklü mü?) — alınan: \(readyLine)")
        }
        connected = true
    }

    /// Köprüye tab-ayrılmış satır komutu gönderir ve JSON yanıtını döndürür.
    private func sendBridge(_ cmd: String, _ args: [String]) async throws -> Any? {
        guard let inputPipe, let outputPipe, connected else {
            throw CDPError(message: "CDP köprüsü bağlı değil. Önce launch() çağır.")
        }
        let argData = try JSONSerialization.data(withJSONObject: args)
        let argString = String(data: argData, encoding: .utf8) ?? "[]"
        let line = cmd + "\t" + argString + "\n"
        inputPipe.fileHandleForWriting.write(Data(line.utf8))
        let respLine = try await readLineFromBuffer()
        guard let data = respLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CDPError(message: "Köprü yanıtı çözümlenemedi")
        }
        if let err = obj["error"] as? String { throw CDPError(message: err) }
        return obj["result"]
    }

    /// Buffer'dan mevcut ilk tam satırı döndürür; yoksa kısa uyku ile bekler.
    private func readLineFromBuffer() async throws -> String {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let line = buffer.takeLine() {
                return line
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        throw CDPError(message: "Köprü yanıt süresi aşıldı (buffer \(buffer.count) byte)")
    }

    func shutdown() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        bridgeProcess?.terminate()
        bridgeProcess = nil
        chromeProcess?.terminate()
        chromeProcess = nil
        outputPipe = nil
        inputPipe = nil
        buffer.removeAll()
        connected = false
    }

    func isConnected() -> Bool { connected }

    // MARK: - DOM işlemleri (köprü üzerinden native hız)

    func navigate(url: String) async throws {
        _ = try await sendBridge("navigate", [url])
    }

    func click(selector: String) async throws -> String {
        guard let r = try await sendBridge("click", [selector]) as? String else { return "?" }
        return r
    }

    func fillField(selector: String, value: String) async throws -> String {
        guard let r = try await sendBridge("fill", [selector, value]) as? String else { return "?" }
        return r
    }

    func readValue(selector: String) async throws -> String {
        (try await sendBridge("read", [selector]) as? String) ?? ""
    }

    func textExists(_ text: String) async throws -> Bool {
        (try await sendBridge("text", [text]) as? Bool) ?? false
    }

    func auditPage() async throws -> String {
        (try await sendBridge("audit", []) as? String) ?? ""
    }

    /// Sayfada rastgele bir JS ifadesi çalıştırır (doğrulama/debug için).
    func evaluateCustom(_ expression: String) async throws -> String {
        (try await sendBridge("evaluate", [expression]) as? String) ?? ""
    }
}

/// Köprü stdout'undan gelen satırları thread-safe biriktiren yardımcı.
/// `readabilityHandler` arka plan thread'inde çalışır; bu sınıf MainActor
/// izolasyonuna tabi değildir, bu yüzden NSLock ile güvenli erişim sağlar.
private final class PipeLineBuffer {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func takeLine() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let line = data[..<idx]
        data.removeSubrange(...idx)
        return String(data: Data(line), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return data.count
    }

    func removeAll() {
        lock.lock()
        data.removeAll()
        lock.unlock()
    }
}

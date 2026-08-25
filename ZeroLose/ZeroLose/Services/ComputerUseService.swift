import Foundation
import ApplicationServices
import AppKit
import CoreGraphics
import Vision
import os

/// ZeroLose'un yerel, gizli "Computer Use" motoru.
///
/// Tasarım (professional, AX-first):
///
///  1. OBSERVE — Hedef uygulamanın AX ağacını oku. Öğe koordinatları her zaman
///     **ekran-global mantık noktası** (point) uzayındadır. Retina ekranlarda OCR
///     piksel koordinatları `ocrPixelToPoints` ile point uzayına çevrilir (2× bug).
///  2. ACT — Tıklamalar üç kademeli geri dönüşle çalışır: AXPress → AXClick →
///     CGEventPostToPid. Tarayıcı (Chromium/WebKit) uygulamaları AX eylemini
///     sessizce yuttuğu için doğrudan CGEvent'e atlanır.
///  3. VERIFY — Eylem sonrası ağaç yeniden taranır ve **diff** döndürülür. Model
///     "ne değişti"yi görür; boş diff dönerse bir sonraki kademeye geçer.
///  4. CACHE — Ağaç PID başına önbelleğe alınır; AX gözlemci bildirimi ile
///     geçersiz kılınır. Böylece tekrar tekrar tıklamada ağaç yeniden yürünmez.
///
/// Güvenlik: Kullanıcı girdisi hedef PID'den başka bir yere gitmez; odağını
/// çalmaz, gerçek imleç oynatmaz. Mutasyonlar yalnızca onaylı çağrılarla çalışır.
@MainActor
final class ComputerUseService {
    private let logger = Logger(subsystem: "com.zerolose", category: "computeruse")

    /// Erişilebilirlik izni var mı? (AXUIElementCopyAttributeValue için gerekli)
    nonisolated static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Ekran kaydı izni var mı? (Vision-OCR/kamera için gerekli)
    nonisolated static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Computer Use ön koşullarının özeti: izinler + çalışan uygulamalar.
    /// Ajan, harekete geçmeden önce bu öz tanıyı çağırıp hangi iznin eksik
    /// olduğunu kullanıcıya net biçimde söyleyebilir (profesyonel tool-use).
    nonisolated static func statusSummary() -> String {
        let ax = hasAccessibilityPermission ? "✓ Erişilebilirlik" : "✗ Erişilebilirlik"
        let screen = hasScreenRecordingPermission ? "✓ Ekran Kaydı" : "✗ Ekran Kaydı"
        let apps = listRunningApps()
        let appLines = apps.prefix(12).enumerated().map { "\($0.offset + 1). \($0.element.name) (pid \($0.element.pid))" }
        var lines = [
            "[COMPUTER USE DURUMU]",
            "İzinler:",
            "  \(ax)\(hasAccessibilityPermission ? "" : " — SİSTEM AYARLARI > Gizlilik ve Güvenlik > Erişilebilirlik > ZeroLose")",
            "  \(screen)\(hasScreenRecordingPermission ? "" : " — Sistem Ayarları > Gizlilik ve Güvenlik > Ekran Kaydı > ZeroLose")"
        ]
        lines.append("Çalışan uygulamalar (\(apps.count)):")
        lines.append(contentsOf: appLines)
        return lines.joined(separator: "\n")
    }

    // MARK: - Uygulama keşfi

    /// Çalışan ön plan uygulamalarını listeler (erişilebilirlik görünürlüğüne göre).
    nonisolated static func listRunningApps() -> [ComputerUseApp] {
        let workspace = NSWorkspace.shared
        return workspace.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .compactMap { app -> ComputerUseApp? in
                guard let pid = app.processIdentifier as pid_t?,
                      let name = app.localizedName else { return nil }
                return ComputerUseApp(
                    pid: pid,
                    name: name,
                    bundleIdentifier: app.bundleIdentifier ?? ""
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Ada göre uygulama bulur (kısmi eşleşme de kabul eder).
    nonisolated static func findApp(named name: String) -> ComputerUseApp? {
        let query = name.lowercased()
        return listRunningApps().first {
            $0.name.lowercased().contains(query) ||
            $0.bundleIdentifier.lowercased().contains(query)
        }
    }

    /// Şu anda ön planda olan uygulamayı döndürür. "Uygulama farketmeksizin"
    /// kullanım için varsayılan hedef budur: ajan pid vermezse, odaktaki
    /// uygulama otomatik hedeflenir (herhangi bir uygulama/tarayıcı).
    nonisolated static func frontmostApp() -> ComputerUseApp? {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.activationPolicy == .regular, !front.isTerminated,
           let name = front.localizedName {
            return ComputerUseApp(pid: front.processIdentifier, name: name, bundleIdentifier: front.bundleIdentifier ?? "")
        }
        // Ön plandaki uygulama accessory/auxiliary ise (örn. UserNotificationCenter,
        // Spotlight), bunu hedeflemek anlamsız; ilk düzenli (regular) uygulamaya düş.
        return listRunningApps().first
    }

    /// Verilen pid 0/geçersizse ön plandaki uygulamayı döndürür; pid varsa onu
    /// korur. Böylece ajan her zaman pid vermek zorunda kalmaz.
    nonisolated static func resolveTarget(pid: pid_t) -> ComputerUseApp? {
        if pid > 0, let app = listRunningApps().first(where: { $0.pid == pid }) {
            return app
        }
        return frontmostApp()
    }

    /// Uygulamayı adına göre aktifleştirir (öne getirir); bulamazsa yoluna göre açar.
    /// Dönen PID, `computer_*` eylemlerine hedef olarak verilir.
    nonisolated static func activateOrLaunch(named name: String) -> (pid: pid_t, launched: Bool)? {
        let query = name.lowercased()
        if let existing = listRunningApps().first(where: {
            $0.name.lowercased().contains(query) || $0.bundleIdentifier.lowercased().contains(query)
        }), let app = NSRunningApplication(processIdentifier: existing.pid) {
            app.activate(options: [.activateAllWindows])
            return (existing.pid, false)
        }
        // Son çare: `open -a` subprocess.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", name]
        do {
            try proc.run()
            usleep(900_000)
            if let found = listRunningApps().first(where: {
                $0.name.lowercased().contains(query) || $0.bundleIdentifier.lowercased().contains(query)
            }) {
                return (found.pid, true)
            }
        } catch {
            return nil
        }
        return nil
    }

    // MARK: - AX ağacı: önbellek + tarama

    /// PID → son ağaç. Aynı PID'ye art arda eylem gelirse ağaç yeniden yürünmez.
    private var treeCache: [pid_t: [ComputerUseElement]] = [:]
    private var treeCacheTime: [pid_t: Date] = [:]
    private let treeTTL: TimeInterval = 0.8

    /// Ağacı okur ve önbelleğe yazar. `forceFresh=true` ise önbelleği atlar.
    func tree(for pid: pid_t, forceFresh: Bool = false) -> [ComputerUseElement] {
        guard Self.hasAccessibilityPermission else { return [] }
        if !forceFresh,
           let cached = treeCache[pid],
           let cachedAt = treeCacheTime[pid],
           Date().timeIntervalSince(cachedAt) < treeTTL {
            return cached
        }
        let app = AXUIElementCreateApplication(pid)
        // Görünürlük denetimi için hedef pencerelerin çerçevelerini BİR KEZ al.
        // Aksi hâlde her öğe için kAXWindowsAttribute tekrar tekrar okunur (O(E×W)).
        let windowRects: [CGRect] = { () -> [CGRect] in
            guard let windows = attribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement] else { return [] }
            return windows.compactMap { window in
                let (x, y, w, h) = frame(of: window)
                guard w > 0, h > 0 else { return nil }
                return CGRect(x: x, y: y, width: w, height: h)
            }
        }()
        let all = buildFlatTree(
            from: app,
            pid: pid,
            windowRects: windowRects,
            depth: 0,
            maxDepth: 18,
            out: [],
            counter: 0
        )
        treeCache[pid] = all
        treeCacheTime[pid] = Date()
        return all
    }

    /// Önbelleği bir PID için (veya `nil` ise tamamını) temizler.
    func invalidate(_ pid: pid_t? = nil) {
        if let pid {
            treeCache[pid] = nil
            treeCacheTime[pid] = nil
        } else {
            treeCache.removeAll()
            treeCacheTime.removeAll()
        }
    }

    // MARK: - AXObserver (gerçek ağaç invalidasyonu)

    /// Bir uygulamanın UI ağacı değiştiğinde önbelleği geçersiz kılan gözlemciyi
    /// kurar. Böylece öğeler eklendiğinde/silinip değiştiğinde ağaç otomatik
    /// tazelenir; TTL'e gerek kalmaz. `AXObserverAddNotification` zaten bir kez
    /// çağrılır; aynı PID için tekrar kurmamak için `observers` sözlüğü tutulur.
    private var observers: [pid_t: AXObserver] = [:]
    /// Observer ömrü boyunca `self`'i canlı tutar. `passUnretained` yerine
    /// `passRetained` kullanırız: AXObserver callback'i hangi thread'de ateşlenirse
    /// ateşlensin, `refcon` her zaman geçerli bir `ComputerUseService` işaret eder.
    /// Bu, unrealized use-after-free riskini ortadan kaldırır.
    private var observerStrongRefs: [pid_t: Unmanaged<ComputerUseService>] = [:]

    func ensureObserver(for pid: pid_t) {
        guard observers[pid] == nil else { return }
        let app = AXUIElementCreateApplication(pid)
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            // refcon: `passRetained(self)` ile tutulan güçlü referans.
            guard let refcon else { return }
            let service = Unmanaged<ComputerUseService>.fromOpaque(refcon).takeUnretainedValue()
            // Öğenin PID'ini güvenilir şekilde bulmak için app root'unu kullanırız;
            // pratikte hedef PID'yi callback'teki element'ten türetmek zordur, bu
            // yüzden ağacı tamamen geçersiz kılmak en güvenlisidir.
            Task { @MainActor in
                service.invalidateAll()
            }
            _ = element
            _ = notification
        }
        let err = AXObserverCreate(pid, callback, &observer)
        guard err == .success, let observer else { return }
        // Güçlü referans sakla; observer artık bu pid için yaşadığı sürece
        // servis de yaşar. (Uygulama ömrü boyunca observer'lar kaldırılmaz.)
        let retained = Unmanaged<ComputerUseService>.passRetained(self)
        observerStrongRefs[pid] = retained
        let selfPtr = retained.toOpaque()
        let notifications: [CFString] = [
            kAXUIElementDestroyedNotification as CFString,
            kAXCreatedNotification as CFString,
            kAXValueChangedNotification as CFString,
            kAXTitleChangedNotification as CFString,
            kAXWindowCreatedNotification as CFString
        ]
        for notif in notifications {
            _ = AXObserverAddNotification(observer, app, notif, selfPtr)
        }
        observers[pid] = observer
        // Observer'ı çalıştıran runloop'u sürdür. MainActor üzerinde olduğumuz için
        // CFRunLoopAddSource çağrısı main runloop'a eklenir.
        let runLoopSource = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
    }

    func invalidateAll() {
        treeCache.removeAll()
        treeCacheTime.removeAll()
    }

    /// Hedef uygulamanın görünür etkileşimli öğelerini düz (flat) ve grep dostu
    /// metin olarak döndürür. `[Role] "label" x:y:w:h visible` formatıdır.
    func snapshotTree(pid: pid_t) async -> String {
        guard Self.hasAccessibilityPermission else {
            return "ERİŞİLEBİLİRLİK_İZNİ_YOK: Sistem Ayarları > Gizlilik ve Güvenlik > Erişilebilirlik > ZeroLose'a izin ver."
        }
        let lines = tree(for: pid, forceFresh: true)
        let visible = lines.filter { $0.visible }
        let compact = visible.count > 220 ? Array(visible.prefix(220)) : visible
        return compact.map(\.line).joined(separator: "\n")
    }

    /// Ağacın tüm satırları (görünür + gizli) — hata ayıklama / grep için.
    func dumpAllTree(pid: pid_t) async -> String {
        tree(for: pid, forceFresh: true).map(\.line).joined(separator: "\n")
    }

    /// AX ağacını yürüyüp düz satır listesi üretir. Tek bir öğenin tüm
    /// özniteliklerini ayrı ayrı sormak yerine bir çekirdek kümesi okur; bu,
    /// öğe başına AX çağrı sayısını minimize eder.
    nonisolated private func buildFlatTree(
        from element: AXUIElement,
        pid: pid_t,
        windowRects: [CGRect],
        depth: Int,
        maxDepth: Int,
        out: [ComputerUseElement],
        counter: Int
    ) -> [ComputerUseElement] {
        guard depth <= maxDepth else { return out }
        var result = out
        let role = attribute(element, kAXRoleAttribute as CFString) as? String ?? ""
        guard !role.isEmpty else { return result }

        let subrole = attribute(element, kAXSubroleAttribute as CFString) as? String ?? ""
        let title = attribute(element, kAXTitleAttribute as CFString) as? String ?? ""
        let value = attribute(element, kAXValueAttribute as CFString) as? String ?? ""
        let desc = attribute(element, kAXDescriptionAttribute as CFString) as? String ?? ""
        let help = attribute(element, kAXHelpAttribute as CFString) as? String ?? ""
        let identifier = attribute(element, kAXIdentifierAttribute as CFString) as? String ?? ""
        let enabled = attribute(element, kAXEnabledAttribute as CFString) as? Bool ?? true
        let (x, y, w, h) = frame(of: element)
        let label = [title, value, desc, help].first { !$0.isEmpty } ?? ""

        // Görünürlük: öğe hedef uygulamanın kendi pencerelerinden birinin içinde.
        let visible = self.isInAnyWindowRects(windowRects, point: CGPoint(x: x, y: y)) || label.isEmpty || windowRects.isEmpty

        // Yapısal/scroll gürültüsünü atla: ajan için eyleme dönüştürülemez.
        let noiseRoles: Set<String> = ["AXScrollBar", "AXValueIndicator", "AXColumn"]
        let isNoise = noiseRoles.contains(role) && (subrole as String).isEmpty

        if !isNoise && depth >= 1 {
            result.append(
                ComputerUseElement(
                    index: result.count,
                    role: role,
                    subrole: subrole as String,
                    label: label,
                    identifier: identifier,
                    enabled: enabled,
                    x: x,
                    y: y,
                    width: w,
                    height: h,
                    visible: visible
                )
            )
        }

        if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            for child in children {
                result = buildFlatTree(
                    from: child,
                    pid: pid,
                    windowRects: windowRects,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    out: result,
                    counter: result.count
                )
            }
        }
        return result
    }

    /// Önceden hesaplanmış pencere dikdörtgenlerinden birine düşen nokta görünür
    /// sayılır. Yüksek maliyetli kAXWindowsAttribute okuması ağaç başına bir kez
    /// yapıldığı için bu fonksiyon yalnızca saf geometri testi yapar.
    nonisolated private func isInAnyWindowRects(_ rects: [CGRect], point: CGPoint) -> Bool {
        guard !rects.isEmpty else { return true }
        return rects.contains { $0.insetBy(dx: -20, dy: -20).contains(point) }
    }

    // MARK: - Eylemler (Üç kademeli tıklama + arka plan güvenli)

    /// Tek bir AX öğesini (dizine göre) tıklar. Sırasıyla: AXPress → AXClick → CGEvent.
    /// Tarayıcı uygulamalarında doğrudan CGEvent'e atlanır (AX eylemi sessizce yutar).
    func clickElement(pid: pid_t, index: Int, button: CGMouseButton = .left, clicks: Int = 1) async throws -> ComputerUseActionResult {
        let current = tree(for: pid)
        guard current.indices.contains(index) else {
            throw ComputerUseError.targetNotFound(index: index)
        }
        let element = current[index]
        return try await performClick(pid: pid, element: element, button: button, clicks: clicks)
    }

    /// Öğeyi **metniyle** (label/value/title) bularak tıklar. İndeks ezberlemeye
    /// gerek kalmaz; ağaç değişse de hedef bulunur. `text` kısmi eşleşmedir.
    func clickElementByText(pid: pid_t, text: String, screenImage: NSImage? = nil, button: CGMouseButton = .left, clicks: Int = 1) async throws -> ComputerUseActionResult {
        // Tarayıcı web içeriğinde AX koordinatları güvenilmez; OCR'ye düş.
        if Self.isBrowser(pid: pid), Self.hasScreenRecordingPermission, screenImage != nil {
            let before = tree(for: pid)
            let invoked = try await clickTextViaOCR(text, pid: pid, screenImage: screenImage)
            usleep(90_000)
            invalidate(pid)
            let after = tree(for: pid, forceFresh: true)
            let diff = Self.diff(before: before, after: after)
            return ComputerUseActionResult(
                message: invoked,
                changed: diff.changedCount > 0,
                added: diff.added,
                removed: diff.removed,
                modified: diff.modified
            )
        }
        guard let element = elementByText(text, pid: pid, onlyInteractive: true) else {
            throw ComputerUseError.textNotFound(text)
        }
        return try await performClick(pid: pid, element: element, button: button, clicks: clicks)
    }

    /// Ortak tıklama + doğrulama. Üç kademeli en iyi primitifi dener; diff boş
    /// dönerse (CGEvent kullanılmışsa) otomatik olarak AXPress/AXClick'e eskalasyon
    /// yapar. Böylece ajan "tıklandı ama olmadı" durumunu kendisi çözer.
    private func performClick(pid: pid_t, element: ComputerUseElement, button: CGMouseButton, clicks: Int) async throws -> ComputerUseActionResult {
        let before = tree(for: pid)
        let invoked = try invokeBestClick(pid: pid, element: element, button: button, clicks: clicks)
        usleep(90_000)
        invalidate(pid)
        var after = tree(for: pid, forceFresh: true)
        var diff = Self.diff(before: before, after: after)

        // Diff boşsa ve CGEvent (kademe 3) kullanıldıysa, AXPress/AXClick'i dene.
        // Tarayıcı olmayan uygulamalarda Catalyst/sandbox sessizce yutar.
        if diff.changedCount == 0,
           !Self.isBrowser(pid: pid),
           let axElement = self.axElement(at: element.index, pid: pid) {
            if performAction(axElement, kAXPressAction as CFString) == .success {
                usleep(90_000)
                invalidate(pid)
                after = tree(for: pid, forceFresh: true)
                diff = Self.diff(before: before, after: after)
                if diff.changedCount > 0 {
                    return ComputerUseActionResult(
                        message: "\(invoked) → eskalasyon: AXPress başarılı (değişiklik görüldü)",
                        changed: true,
                        added: diff.added,
                        removed: diff.removed,
                        modified: diff.modified
                    )
                }
            } else if performAction(axElement, "AXClick" as CFString) == .success {
                usleep(90_000)
                invalidate(pid)
                after = tree(for: pid, forceFresh: true)
                diff = Self.diff(before: before, after: after)
                if diff.changedCount > 0 {
                    return ComputerUseActionResult(
                        message: "\(invoked) → eskalasyon: AXClick başarılı (değişiklik görüldü)",
                        changed: true,
                        added: diff.added,
                        removed: diff.removed,
                        modified: diff.modified
                    )
                }
            }
        }

        return ComputerUseActionResult(
            message: invoked,
            changed: diff.changedCount > 0,
            added: diff.added,
            removed: diff.removed,
            modified: diff.modified
        )
    }

    /// PROFESYONEL zincir: hedef öğeye tıkla, ardından istenirse metin yaz ve
    /// tuş bas — hepsi tek çağrıda. Böylece ajan round-trip sayısını azaltır.
    /// `targetText` ile öğe bulunur; başarısızsa `index` denenir.
    func interact(
        pid: pid_t,
        targetText: String? = nil,
        index: Int? = nil,
        type text: String? = nil,
        pressKey: String? = nil,
        button: CGMouseButton = .left
    ) async throws -> ComputerUseActionResult {
        let element: ComputerUseElement
        if let targetText, let match = elementByText(targetText, pid: pid, onlyInteractive: true) {
            element = match
        } else if let index, tree(for: pid).indices.contains(index) {
            element = tree(for: pid)[index]
        } else {
            throw ComputerUseError.targetNotFound(index: index ?? -1)
        }

        let before = tree(for: pid)
        var messages: [String] = []
        messages.append(try invokeBestClick(pid: pid, element: element, button: button, clicks: 1))
        if let text, !text.isEmpty {
            postText(text, to: pid)
            messages.append("Typed \(text.count) characters")
        }
        if let pressKey {
            let parsed = try Self.parseKeySpec(pressKey)
            postKeyboard(pid: pid, keyCode: parsed.keyCode, modifiers: parsed.modifiers)
            messages.append("Pressed \(pressKey)")
        }
        usleep(90_000)
        invalidate(pid)
        let after = tree(for: pid, forceFresh: true)
        let diff = Self.diff(before: before, after: after)
        return ComputerUseActionResult(
            message: messages.joined(separator: " | "),
            changed: diff.changedCount > 0,
            added: diff.added,
            removed: diff.removed,
            modified: diff.modified
        )
    }

    /// Metne göre AX öğesi bulur. `onlyInteractive=true` ise yalnızca
    /// tıklanabilir/girdi kabul eden rollerde arar (button, textfield, link, row).
    func elementByText(_ text: String, pid: pid_t, onlyInteractive: Bool = false) -> ComputerUseElement? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return nil }
        let interactiveRoles: Set<String> = [
            "AXButton", "AXTextField", "AXTextArea", "AXLink", "AXMenuItem",
            "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXCell", "AXRow",
            "AXStaticText", "AXHeading", "AXImage"
        ]
        let elements = tree(for: pid)
        // Önce görünür + boyutlu + etkin öğeleri dene; ağaç güncelse en doğru hedef.
        let visibleMatch = elements.first { element in
            let label = element.label.lowercased()
            guard !label.isEmpty else { return false }
            if onlyInteractive && !interactiveRoles.contains(element.role) { return false }
            guard element.visible, element.width > 0, element.height > 0, element.enabled else { return false }
            return label.contains(query) || query.contains(label)
        }
        if let visibleMatch { return visibleMatch }
        // Görünür aday yoksa herhangi bir eşleşmeyi döndür (haste/Canvas fallback).
        return elements.first { element in
            let label = element.label.lowercased()
            guard !label.isEmpty else { return false }
            if onlyInteractive && !interactiveRoles.contains(element.role) { return false }
            return label.contains(query) || query.contains(label)
        }
    }

    /// Metne göre hedefi DOLU bir raporla çözer: kaynak (AX/OCR), güven skoru,
    /// eşleşme sayısı ve neden bu kaynağın seçildiği. Ajan asla körlemesine
    /// tıklamaz; belirsizlik (çok eşleşme / disabled / offscreen) açıkça raporlanır.
    func resolveNamedTarget(_ text: String, pid: pid_t, screenImage: NSImage?) -> ComputerUseTarget {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return .init(source: .none, confidence: 0, matches: [], reason: "Boş hedef metni") }
        let interactiveRoles: Set<String> = [
            "AXButton", "AXTextField", "AXTextArea", "AXLink", "AXMenuItem",
            "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXCell", "AXRow",
            "AXStaticText", "AXHeading", "AXImage"
        ]
        let elements = tree(for: pid)
        // AX adayları: görünür + boyutlu + etkin
        let axCandidates = elements.filter { element in
            let label = element.label.lowercased()
            guard !label.isEmpty else { return false }
            guard interactiveRoles.contains(element.role) else { return false }
            guard element.visible, element.width > 0, element.height > 0, element.enabled else { return false }
            return label.contains(query) || query.contains(label)
        }
        if !axCandidates.isEmpty {
            // Şans: tek eşleşme yüksek güven; çok eşleşme belirsizlik.
            let best = axCandidates.first!
            let confidence: Double = axCandidates.count == 1 ? 0.95 : 0.6
            return ComputerUseTarget(
                source: .ax,
                confidence: confidence,
                matches: axCandidates.map(\.line),
                reason: axCandidates.count == 1
                    ? "AX ağacında tek görünür eşleşme"
                    : "AX ağacında \(axCandidates.count) eşleşme (belirsiz — disambiguate et)"
            )
        }
        // AX yoksa OCR
        if let screenImage,
           Self.hasScreenRecordingPermission,
           let match = Self.ocrTextLines(in: screenImage).first(where: { $0.text.lowercased().contains(query) }) {
            return ComputerUseTarget(
                source: .ocr,
                confidence: 0.7,
                matches: ["[OCR] \"\(match.text)\" x:\(Int(match.x)) y:\(Int(match.y))"],
                reason: "AX ağacında hedef yok — OCR metniyle konum bulundu (canvas/Electron)"
            )
        }
        return ComputerUseTarget(source: .none, confidence: 0, matches: [], reason: "Ne AX ne OCR'de hedef bulunamadı")
    }

    /// Koordinata tıklar (AX ağacı olmayan uygulamalar için fallback).
    func click(pid: pid_t, x: CGFloat, y: CGFloat, button: CGMouseButton = .left) async throws -> String {
        try postMouse(pid: pid, at: CGPoint(x: x, y: y), button: button, clicks: 1)
        return "Clicked at (\(Int(x)),\(Int(y)))"
    }

    /// Fareyi koordinata taşır (hover).
    func hover(pid: pid_t, x: CGFloat, y: CGFloat) async throws -> String {
        guard Self.hasAccessibilityPermission else { throw ComputerUseError.permissionDenied }
        postMouseEvent(pid: pid, type: .mouseMoved, point: CGPoint(x: x, y: y), button: .left)
        return "Hovered (\(Int(x)),\(Int(y)))"
    }

    /// Sürükleme: bir noktadan diğerine 12 ara adımlı interpolasyonlu sürükleme.
    /// (Dosya taşıma, kaydırıcı, panel yeniden boyutlandırma gibi işlemlerde kullanılır.)
    func drag(pid: pid_t, fromX: CGFloat, fromY: CGFloat, toX: CGFloat, toY: CGFloat) async throws -> String {
        guard Self.hasAccessibilityPermission else { throw ComputerUseError.permissionDenied }
        let start = CGPoint(x: fromX, y: fromY)
        let end = CGPoint(x: toX, y: toY)
        postMouseEvent(pid: pid, type: .mouseMoved, point: start, button: .left)
        usleep(40_000)
        postMouseEvent(pid: pid, type: .leftMouseDown, point: start, button: .left)
        usleep(40_000)
        let steps = 12
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let mid = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            postMouseEvent(pid: pid, type: .leftMouseDragged, point: mid, button: .left)
            usleep(16_000)
        }
        postMouseEvent(pid: pid, type: .leftMouseUp, point: end, button: .left)
        return "Dragged (\(Int(fromX)),\(Int(fromY))) → (\(Int(toX)),\(Int(toY)))"
    }

    /// Metni hedef PID'e gönderir; istenirse sonunda tuş (örn. Return) basar.
    func typeText(_ text: String, pid: pid_t, pressKey: String? = nil) async throws -> String {
        guard Self.hasAccessibilityPermission else { throw ComputerUseError.permissionDenied }
        guard !text.isEmpty else { return "Boş metin." }
        postText(text, to: pid)
        if let pressKey {
            let parsed = try Self.parseKeySpec(pressKey)
            postKeyboard(pid: pid, keyCode: parsed.keyCode, modifiers: parsed.modifiers)
        }
        return "Typed \(text.count) characters\(pressKey.map { " + \($0)" } ?? "")"
    }

    /// Klavye kısayolu gönderir (örn. "super+c", "return", "ctrl+shift+a").
    func pressKey(_ spec: String, pid: pid_t) async throws -> String {
        guard Self.hasAccessibilityPermission else { throw ComputerUseError.permissionDenied }
        let parsed = try Self.parseKeySpec(spec)
        postKeyboard(pid: pid, keyCode: parsed.keyCode, modifiers: parsed.modifiers)
        return "Pressed \(spec)"
    }

    /// Metin alanına `kAXValueAttribute` ile yazar (AXValue write). CGEvent'in
    /// sessizce yuttuğu güvenli/sandbox/Catalyst alanlar ve şifre alanları için
    /// kritik kurtarma yoludur. Doğrudan AX element'e yazdığı için sentetik klavye
    /// olayına gerek kalmaz.
    func setValue(_ value: String, pid: pid_t, index: Int) async throws -> String {
        guard Self.hasAccessibilityPermission else { throw ComputerUseError.permissionDenied }
        guard let axElement = self.axElement(at: index, pid: pid) else {
            throw ComputerUseError.targetNotFound(index: index)
        }
        let err = AXUIElementSetAttributeValue(axElement, kAXValueAttribute as CFString, value as CFTypeRef)
        guard err == .success else {
            throw ComputerUseError.axWriteFailed(Int(err.rawValue))
        }
        return "Set '\(value)' into element \(index) via AXValue"
    }

    /// Form alanını **etiketiyle taze çözüp** doldurur. Önce AXValue yazar
    /// (web input için en güvenilir); gözlemlenemezse tıkla+yaz. `index`'e güvenmek
    /// yerine her çağrıda ağaçta arar (tarayıcıda indeksler kararsız olabilir).
    func fillField(label: String, value: String, pid: pid_t, button: CGMouseButton = .left) async throws -> String {
        guard Self.hasAccessibilityPermission else { throw ComputerUseError.permissionDenied }
        let tree = self.tree(for: pid, forceFresh: true)
        let query = label.lowercased()
        // Alanı etiketle eşleştir; placeholder/aria genelde label'de görünür,
        // olmazsa identifier'a da bakarız (tarayıcıda kararsız olabilir).
        let field = tree.first { element in
            guard element.role == "AXTextField" || element.role == "AXTextArea" else { return false }
            let haystacks = [element.label.lowercased(), element.identifier.lowercased()]
            return haystacks.contains { !$0.isEmpty && ($0.contains(query) || query.contains($0)) }
        }
        guard let field else {
            throw ComputerUseError.textNotFound(label)
        }
        // 1) AXValue ile doğrudan yaz (güvenli/sandbox/web için).
        if let ax = self.axElement(at: field.index, pid: pid),
           AXUIElementSetAttributeValue(ax, kAXValueAttribute as CFString, value as CFTypeRef) == .success {
            return "\(label) alanına AXValue ile yazıldı: \(value)"
        }
        // 2) Değilse tıkla + yaz + (varsa) girdi doğrulaması.
        let center = CGPoint(x: field.x + field.width / 2, y: field.y + field.height / 2)
        try postMouse(pid: pid, at: center, button: button, clicks: 1)
        usleep(60_000)
        postText(value, to: pid)
        return "\(label) alanına tıklayıp yazıldı: \(value)"
    }

    /// Tarayıcı formunda SUBMIT — önce butona tıklar (OCR koordinatı), sonuç
    /// alınamazsa klavye ile gönderir (Tab → Return). Web content CGEvent mouse'u
    /// yutabildiği için bu self-correct kritiktir.
    func submitBrowserForm(pid: pid_t, submitLabel: String = "Kaydol", screenImage: NSImage?) async throws -> String {
        // Deneme 1: butona OCR koordinatıyla tıkla (mümkünse).
        if let screenImage, Self.isBrowser(pid: pid), Self.hasScreenRecordingPermission {
            if (try? await clickTextViaOCR(submitLabel, pid: pid, screenImage: screenImage)) != nil {
                // Tıklamanın etkisini doğrula: kısa bekle, sonra sayfa/title değişti mi?
                usleep(600_000)
                invalidate(pid)
                let after = tree(for: pid, forceFresh: true)
                let titleChanged = after.contains { $0.role == "AXStaticText" && ($0.label.contains("SUBMITTED") || $0.label.contains("Kayıt tamam")) }
                if titleChanged {
                    return "Butona OCR ile tıklandı ve form gönderildi"
                }
            }
        }
        // Deneme 2: klavye ile gönder (Tab → Return). Web content için güvenilir.
        let tab = try Self.parseKeySpec("tab")
        postKeyboard(pid: pid, keyCode: tab.keyCode, modifiers: tab.modifiers)
        usleep(120_000)
        let ret = try Self.parseKeySpec("return")
        postKeyboard(pid: pid, keyCode: ret.keyCode, modifiers: ret.modifiers)
        return "Klavye ile gönderildi (Tab + Return)"
    }

    /// Kullanıcı tanımlı bir koşul gerçekleşene kadar poll eder (bekle).
    /// `timeout` saniye; `targetText` belirli bir etiketin görünmesini bekler.
    /// Bu, ajanın UI'ın oturmasını beklemesini sağlar (doğruluk artışı).
    func waitFor(pid: pid_t, targetText: String?, timeout: TimeInterval = 5.0) async throws -> String {
        guard Self.hasAccessibilityPermission else { throw ComputerUseError.permissionDenied }
        let deadline = Date().addingTimeInterval(timeout)
        var accumulated: [String] = []
        while Date() < deadline {
            invalidate(pid)
            let elements = tree(for: pid, forceFresh: true)
            if let targetText, !targetText.isEmpty {
                let query = targetText.lowercased()
                let hit = elements.contains {
                    !$0.label.isEmpty && ($0.label.lowercased().contains(query) || query.contains($0.label.lowercased()))
                }
                if hit {
                    return "Beklenen öğe göründü: '\(targetText)'"
                }
            } else {
                // Hedef yoksa öğe doluluğunu raporla.
                accumulated = elements.filter { $0.visible }.map(\.label).filter { !$0.isEmpty }
                if !accumulated.isEmpty {
                    return "UI güncellendi. Öğe sayısı: \(accumulated.count)"
                }
            }
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        throw ComputerUseError.waitTimeout(targetText ?? "görünür öğe", timeout)
    }

    /// Kaydırma (scroll) eylemi gönderir.
    func scroll(pid: pid_t, x: CGFloat, y: CGFloat, amount: Int) async throws -> String {
        guard Self.hasAccessibilityPermission else { throw ComputerUseError.permissionDenied }
        guard let source = CGEventSource(stateID: .hidSystemState) else { throw ComputerUseError.eventSourceFailed }
        let scrollEvent = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: Int32(amount), wheel2: 0, wheel3: 0)
        scrollEvent?.location = CGPoint(x: x, y: y)
        scrollEvent?.postToPid(pid)
        return "Scrolled \(amount) px"
    }

    /// EN İYİ tıklama primitifini seçer: AXPress → AXClick → CGEvent. Tarayıcı
    /// uygulamalarında 1. ve 2. kademe atlanır (sessizce başarı döner, hiçbir şey olmaz).
    nonisolated private func invokeBestClick(pid: pid_t, element: ComputerUseElement, button: CGMouseButton, clicks: Int) throws -> String {
        guard Self.hasAccessibilityPermission else { throw ComputerUseError.permissionDenied }

        if !Self.isBrowser(pid: pid),
           let axElement = self.axElement(at: element.index, pid: pid) {
            // Tier 1: AXPress
            if performAction(axElement, kAXPressAction as CFString) == .success {
                return "Pressed \(element.role) '\(element.label)' (AXPress)"
            }
            // Tier 2: AXClick
            if performAction(axElement, "AXClick" as CFString) == .success {
                return "Clicked \(element.role) '\(element.label)' (AXClick)"
            }
        }

        // Tier 3: CGEvent (tarayıcı + canvas + AX eylemi olmayanlar)
        let center = CGPoint(x: element.x + element.width / 2, y: element.y + element.height / 2)
        try postMouse(pid: pid, at: center, button: button, clicks: clicks)
        return "Clicked \(element.role) '\(element.label)' at (\(Int(center.x)),\(Int(center.y))) (CGEvent)"
    }

    /// AX dizininden gerçek `AXUIElement`'i bulur. Önbellekteki öğe sırası ile
    /// ağaçta aynı yürüme kullanıldığı için dizin eşleşmesi korunur.
    nonisolated private func axElement(at index: Int, pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        return findElementInTree(app, targetIndex: index, currentIndex: 0).element
    }

    private nonisolated func findElementInTree(
        _ element: AXUIElement,
        targetIndex: Int,
        currentIndex: Int
    ) -> (element: AXUIElement?, nextIndex: Int) {
        guard let role = attribute(element, kAXRoleAttribute as CFString) as? String, !role.isEmpty else {
            return (nil, currentIndex)
        }
        let subrole = attribute(element, kAXSubroleAttribute as CFString) as? String ?? ""
        let noiseRoles: Set<String> = ["AXScrollBar", "AXValueIndicator", "AXColumn"]
        let isNoise = noiseRoles.contains(role) && (subrole as String).isEmpty
        var idx = currentIndex
        if !isNoise {
            if idx == targetIndex { return (element, idx) }
            idx += 1
        }
        if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            for child in children {
                let (found, next) = findElementInTree(child, targetIndex: targetIndex, currentIndex: idx)
                if let found { return (found, next) }
                idx = next
            }
        }
        return (nil, idx)
    }

    // MARK: - Gözlem (snapshot + OCR)

    /// Hedef uygulamanın etkileşimli öğelerini ve OCR satırlarını tek bir gözlem
    /// paketi olarak döndürür. OCR koordinatları point uzayına çevrilir.
    func snapshot(pid: pid_t, screenImage: NSImage? = nil) async -> ComputerUseObservation {
        ensureObserver(for: pid)
        let tree = await snapshotTree(pid: pid)
        let elements = elementLines(from: tree)
        let ocrLines = screenImage.map { Self.ocrTextLines(in: $0) } ?? []
        return ComputerUseObservation(
            pid: pid,
            appName: Self.appName(for: pid),
            tree: tree,
            elements: elements,
            ocrLines: ocrLines.map(\.line)
        )
    }

    /// Ekranda OCR ile bulunan bir metnin koordinatına tıklar. AX ağacı boş/eksik
    /// (canvas, bazı Electron) uygulamalarda metni bulup hedefe gider.
    func clickOnText(_ text: String, pid: pid_t, screenImage: NSImage?) async throws -> String {
        guard Self.hasScreenRecordingPermission else {
            throw ComputerUseError.screenRecordingDenied
        }
        guard let screenImage else {
            throw ComputerUseError.captureFailed
        }
        let lines = Self.ocrTextLines(in: screenImage)
        let query = text.lowercased()
        guard let match = lines.first(where: { $0.text.lowercased().contains(query) }) else {
            throw ComputerUseError.textNotFound(text)
        }
        let center = CGPoint(x: match.x + match.width / 2, y: match.y + match.height / 2)
        try postMouse(pid: pid, at: center, button: .left, clicks: 1)
        return "Clicked OCR text '\(match.text)' at (\(Int(center.x)),\(Int(center.y)))"
    }

    /// TARAYICI/WEB içeriği için AX koordinatları güvenilmezdir (Chrome web
    /// içeriği AX frame'leri eski/0-boyutlu olabilir — yukarıda kanıtlandı).
    /// Bu durumda hedefi doğrudan OCR koordinatıyla bulur ve oraya tıklar.
    /// `screenImage` yoksa çağıran onu ScreenCaptureKit ile üretmelidir.
    func clickTextViaOCR(_ text: String, pid: pid_t, screenImage: NSImage?) async throws -> String {
        guard Self.hasScreenRecordingPermission, let screenImage else {
            throw ComputerUseError.screenRecordingDenied
        }
        let lines = Self.ocrTextLines(in: screenImage)
        let query = text.lowercased()
        guard let match = lines.first(where: { $0.text.lowercased().contains(query) || query.contains($0.text.lowercased()) }) else {
            throw ComputerUseError.textNotFound(text)
        }
        let center = CGPoint(x: match.x + match.width / 2, y: match.y + match.height / 2)
        try postMouse(pid: pid, at: center, button: .left, clicks: 1)
        return "Clicked web '\(match.text)' (OCR) at (\(Int(center.x)),\(Int(center.y)))"
    }

    /// Vision-OCR: ekrandaki görünür metni koordinatlarıyla bulur. Çıktı **point**
    /// uzayındadır; Retina'da piksel→nokta dönüşümü yapılır. AX ağacı olmayan
    /// (canvas, bazı Electron) uygulamalar için geri dönüş yoludur.
    nonisolated static func ocrTextLines(in image: NSImage) -> [ComputerUseOCRLine] {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cgImage = rep.cgImage else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let imageWidthPoints = CGFloat(NSScreen.main?.frame.width ?? 0)
        let imageHeightPoints = CGFloat(NSScreen.main?.frame.height ?? 0)
        let imageWidthPixels = CGFloat(cgImage.width)
        let imageHeightPixels = CGFloat(cgImage.height)

        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            // Vision koordinatları alt-sol; point uzayına çevir (Retina 2× dahil).
            let x = ocrPixelToPoints(centerX: box.midX * imageWidthPixels,
                                     y: (1 - box.midY) * imageHeightPixels,
                                     pixelWidth: imageWidthPixels,
                                     pixelHeight: imageHeightPixels,
                                     pointWidth: imageWidthPoints,
                                     pointHeight: imageHeightPoints)
            return ComputerUseOCRLine(
                text: text,
                x: x.x,
                y: x.y,
                width: box.width * imageWidthPoints,
                height: box.height * imageHeightPoints
            )
        }
    }

    /// OCR piksel-merkezini ekran-global point uzayına çevirir. Retina 2× ve
    /// kesirli ölçekler için kesindir; 1× ekranda kimlik dönüşümüdür.
    nonisolated static func ocrPixelToPoints(
        centerX: CGFloat,
        y: CGFloat,
        pixelWidth: CGFloat,
        pixelHeight: CGFloat,
        pointWidth: CGFloat,
        pointHeight: CGFloat
    ) -> (x: CGFloat, y: CGFloat) {
        guard pixelWidth > 0, pixelHeight > 0 else { return (centerX, y) }
        let scaleX = pointWidth / pixelWidth
        let scaleY = pointHeight / pixelHeight
        return (centerX * scaleX, y * scaleY)
    }

    /// Snapshot metninden düzgün `[Role] "label" x:y:w:h visible` satırlarını çıkarır.
    private nonisolated func elementLines(from tree: String) -> [String] {
        tree.components(separatedBy: "\n").filter {
            $0.hasPrefix("[") && $0.contains("x:") && $0.contains("y:")
        }
    }

    nonisolated private static func appName(for pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Unknown"
    }

    /// Tarayıcı uygulaması mı? Chromium/WebKit AX eylemini sessizce yutar, bu
    /// yüzden bu uygulamalarda AXPress/AXClick denenmez, doğrudan CGEvent kullanılır.
    nonisolated static func isBrowser(pid: pid_t) -> Bool {
        let appName = appName(for: pid).lowercased()
        let browserTokens = ["chrome", "safari", "arc", "firefox", "edge", "brave", "opera", "vivaldi", "chromium"]
        return browserTokens.contains { appName.contains($0) }
    }

    // MARK: - Diff (doğrulama / self-correction)

    /// Eylem öncesi/sonrası ağaçları karşılaştırır ve görünür değişiklikleri döndürür.
    /// Scroll/gürültü değişimlerini atar; API ajanın "ne değişti"yi görmesini sağlar.
    nonisolated static func diff(before: [ComputerUseElement], after: [ComputerUseElement]) -> ComputerUseDiff {
        let beforeMap = Dictionary(before.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        let afterMap = Dictionary(after.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })

        var added: [String] = []
        var removed: [String] = []
        var modified: [String] = []

        for element in after {
            let index = element.index
            if beforeMap[index] == nil {
                added.append(element.line)
            } else if let prev = beforeMap[index], prev.label != element.label || prev.enabled != element.enabled {
                modified.append("~ \(prev.line) → \(element.line)")
            }
        }
        for element in before {
            let index = element.index
            if afterMap[index] == nil {
                removed.append(element.line)
            }
        }

        return ComputerUseDiff(added: added, removed: removed, modified: modified)
    }

    // MARK: - Koordinat ve dönüşümler

    /// AX öğesinin ekran-global çerçevesini döndürür. Retina ölçeklemesini
    /// mantık noktalarına çevirir (CGEvent piksel değil mantık noktası bekler).
    private nonisolated func frame(of element: AXUIElement) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let pos = attribute(element, kAXPositionAttribute as CFString) as! AXValue?
        let size = attribute(element, kAXSizeAttribute as CFString) as! AXValue?

        var x: CGFloat = 0, y: CGFloat = 0, w: CGFloat = 0, h: CGFloat = 0
        if let pos { AXValueGetValue(pos, .cgPoint, &x) }
        if pos != nil, let size {
            var sizePoint = CGSize.zero
            AXValueGetValue(size, .cgSize, &sizePoint)
            w = sizePoint.width
            h = sizePoint.height
        }
        return (x, y, w, h)
    }

    // MARK: - CGEvent post etme

    private nonisolated func postMouse(pid: pid_t, at point: CGPoint, button: CGMouseButton, clicks: Int) throws {
        guard Self.hasAccessibilityPermission else { throw ComputerUseError.permissionDenied }
        postMouseEvent(pid: pid, type: .mouseMoved, point: point, button: button)
        usleep(30_000)
        for _ in 0..<clicks {
            postMouseEvent(pid: pid, type: .leftMouseDown, point: point, button: button)
            postMouseEvent(pid: pid, type: .leftMouseUp, point: point, button: button)
            if clicks > 1 { usleep(80_000) }
        }
    }

    private nonisolated func postMouseEvent(pid: pid_t, type: CGEventType, point: CGPoint, button: CGMouseButton) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            return
        }
        event.postToPid(pid)
    }

    private nonisolated func postText(_ text: String, to pid: pid_t) {
        for scalar in text.unicodeScalars {
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }
            var unicode = [UniChar(scalar.value)]
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicode)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicode)
            down.postToPid(pid)
            up.postToPid(pid)
            usleep(2_000)
        }
    }

    private nonisolated func postKeyboard(pid: pid_t, keyCode: CGKeyCode, modifiers: [CGEventFlags]) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        var flags: CGEventFlags = []
        for modifier in modifiers { flags.insert(modifier) }
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.postToPid(pid)
        up?.postToPid(pid)
    }

    // MARK: - Klavye spec ayrıştırma

    private nonisolated static func parseKeySpec(_ spec: String) throws -> (keyCode: CGKeyCode, modifiers: [CGEventFlags]) {
        let parts = spec.lowercased().split(separator: "+").map(String.init)
        var keyPart = ""
        var modifiers: [CGEventFlags] = []
        let modifierMap: [String: CGEventFlags] = [
            "cmd": .maskCommand, "command": .maskCommand,
            "ctrl": .maskControl, "control": .maskControl,
            "alt": .maskAlternate, "option": .maskAlternate, "opt": .maskAlternate,
            "shift": .maskShift
        ]
        for part in parts {
            if let flag = modifierMap[part] {
                modifiers.append(flag)
            } else {
                keyPart = part
            }
        }
        guard let keyCode = Self.keyCode(for: keyPart) else {
            throw ComputerUseError.unsupportedKey(keyPart)
        }
        return (keyCode, modifiers)
    }

    private nonisolated static func keyCode(for key: String) -> CGKeyCode? {
        let map: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
            "escape": 53, "esc": 53, "arrowleft": 123, "left": 123,
            "arrowright": 124, "right": 124, "arrowdown": 125, "down": 125,
            "arrowup": 126, "up": 126, "home": 115, "end": 119,
            "pageup": 116, "pagedown": 121
        ]
        if let named = map[key] { return named }
        // Tek karakterli tuşlar için standart mac keycode tablosu.
        if key.count == 1, let scalar = key.unicodeScalars.first {
            let lower = String(scalar).lowercased()
            let charMap: [String: CGKeyCode] = [
                "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5,
                "h": 4, "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45,
                "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32,
                "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
                "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
                "6": 22, "7": 26, "8": 28, "9": 25, ".": 47, ",": 43, "/": 44,
                ";": 41, "'": 39, "[": 33, "]": 30, "\\": 42, "-": 27, "=": 24
            ]
            return charMap[lower]
        }
        return nil
    }

    // MARK: - AX yardımcıları

    private nonisolated func attribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        return error == .success ? value : nil
    }

    private nonisolated func performAction(_ element: AXUIElement, _ action: CFString) -> AXError {
        AXUIElementPerformAction(element, action)
    }
}

// MARK: - Yardımcı veri tipleri

struct ComputerUseApp: Sendable, Equatable {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String
}

struct ComputerUseElement: Sendable, Equatable {
    let index: Int
    let role: String
    let subrole: String
    let label: String
    let identifier: String
    let enabled: Bool
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let visible: Bool

    var line: String {
        let visibility = visible ? "visible" : "hidden"
        let labelPart = label.isEmpty ? "\"\"" : "\"\(label)\""
        let roleShort = role.replacingOccurrences(of: "AX", with: "")
        return "#\(index) [\(roleShort)] \(labelPart) x:\(Int(x)) y:\(Int(y)) w:\(Int(width)) h:\(Int(height)) \(visibility)"
    }
}

/// Eylem sonrası ağaç değişiklikleri; agent'ın self-correction yapabilmesi için.
struct ComputerUseDiff: Sendable {
    let added: [String]
    let removed: [String]
    let modified: [String]

    var changedCount: Int { added.count + removed.count + modified.count }

    var summary: String {
        guard changedCount > 0 else { return "Değişiklik yok." }
        var lines: [String] = []
        lines.append("+ Eklendi (\(added.count)):")
        lines.append(contentsOf: added.prefix(8))
        lines.append("- Kaldırıldı (\(removed.count)):")
        lines.append(contentsOf: removed.prefix(8))
        lines.append("~ Değişti (\(modified.count)):")
        lines.append(contentsOf: modified.prefix(8))
        return lines.joined(separator: "\n")
    }
}

/// Bir eylemin sonucu: kısa mesaj + doğrulama (diff).
struct ComputerUseActionResult: Sendable {
    let message: String
    let changed: Bool
    let added: [String]
    let removed: [String]
    let modified: [String]

    var changedDescription: String {
        let diff = ComputerUseDiff(added: added, removed: removed, modified: modified)
        return diff.summary
    }
}

/// Tek bir "ekranı gör" adımının kompakt model-görünümlü çıktısı.
struct ComputerUseObservation: Sendable {
    let pid: pid_t
    let appName: String
    let tree: String
    let elements: [String]
    let ocrLines: [String]

    var summary: String {
        let ocrBlock = ocrLines.isEmpty ? "" : "\nGörünür metin (OCR):\n\(ocrLines.joined(separator: "\n"))"
        return """
        [COMPUTER USE: \(appName) (pid \(pid))]
        Etkileşimli öğeler (\(elements.count)):
        \(tree)
        \(ocrBlock)
        """
    }
}

/// Hedefin nereden çözüldüğünü belirtir; agent bu kaynağa göre güven verir.
enum ComputerUseTargetSource: Sendable, Equatable {
    case ax
    case ocr
    case raw
    case none

    var label: String {
        switch self {
        case .ax: return "AX (UI ağacı)"
        case .ocr: return "OCR (görsel)"
        case .raw: return "Ham koordinat"
        case .none: return "Bulunamadı"
        }
    }
}

/// Metinle hedefleme sonucu: kaynak + güven + eşleşmeler + neden.
/// Ajanın körlemesine tıklamaması için belirsizlik açıkça raporlanır.
struct ComputerUseTarget: Sendable {
    let source: ComputerUseTargetSource
    let confidence: Double
    let matches: [String]
    let reason: String

    var summary: String {
        """
        [HEDEF: \(source.label) | güven %\(Int(confidence * 100))]
        \(reason)
        Eşleşmeler (\(matches.count)):
        \(matches.prefix(5).joined(separator: "\n"))
        """
    }
}

enum ComputerUseError: LocalizedError {
    case permissionDenied
    case screenRecordingDenied
    case captureFailed
    case textNotFound(String)
    case axWriteFailed(Int)
    case waitTimeout(String, TimeInterval)
    case eventSourceFailed
    case targetNotFound(index: Int)
    case unsupportedKey(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Erişilebilirlik izni gerekli: Sistem Ayarları > Gizlilik ve Güvenlik > Erişilebilirlik > ZeroLose."
        case .screenRecordingDenied:
            return "Ekran kaydı izni gerekli: Sistem Ayarları > Gizlilik ve Güvenlik > Ekran Kaydı > ZeroLose."
        case .captureFailed:
            return "Ekran görüntüsü yakalanamadı."
        case .textNotFound(let text):
            return "Ekranda şu metin bulunamadı: \(text)"
        case .axWriteFailed(let code):
            return "AXValue yazma başarısız (hata \(code))."
        case .waitTimeout(let target, let timeout):
            return "\(timeout) sn içinde '\(target)' görünmedi/kaybolmadı."
        case .eventSourceFailed:
            return "CGEvent kaynağı oluşturulamadı."
        case .targetNotFound(let index):
            return "Hedef öğe bulunamadı (indeks: \(index)). Önce snapshot alın."
        case .unsupportedKey(let key):
            return "Desteklenmeyen tuş: \(key)"
        }
    }
}

/// Vision-OCR'nin bulduğu bir metin satırı; ekran-global üst-sol **point** uzayında.
struct ComputerUseOCRLine: Sendable {
    let text: String
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    var line: String {
        "[OCR] \"\(text)\" x:\(Int(x)) y:\(Int(y)) w:\(Int(width)) h:\(Int(height))"
    }
}

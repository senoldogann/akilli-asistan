import Foundation
import CoreGraphics

public enum ChromeDevToolsBrowserSemanticError: Error, Equatable, LocalizedError {
    case invalidEndpoint
    case invalidDebuggerURL
    case invalidHTTPResponse
    case httpStatus(Int)
    case responseTooLarge
    case invalidJSON
    case protocolError(String)
    case timeout
    case missingBrowserProcess
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The Chrome DevTools endpoint must be an uncredentialed loopback HTTP URL with no path."
        case .invalidDebuggerURL:
            return "Chrome returned a non-loopback or invalid WebSocket debugger URL."
        case .invalidHTTPResponse:
            return "The Chrome DevTools endpoint returned an invalid HTTP response."
        case .httpStatus(let status):
            return "The Chrome DevTools endpoint returned HTTP \(status)."
        case .responseTooLarge:
            return "The Chrome DevTools response exceeded the configured safety bound."
        case .invalidJSON:
            return "The Chrome DevTools endpoint returned invalid JSON."
        case .protocolError(let message):
            return "Chrome DevTools Protocol error: \(message)."
        case .timeout:
            return "Chrome DevTools Protocol command timed out."
        case .missingBrowserProcess:
            return "Chrome DevTools did not expose exactly one browser process."
        case .invalidResponse:
            return "Chrome DevTools returned an incomplete semantic response."
        }
    }
}

struct ChromeDevToolsEndpoint: Equatable {
    let baseURL: URL
    let versionURL: URL
    let targetsURL: URL

    init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http",
              let host = Self.normalizedHost(components),
              Self.loopbackHosts.contains(host),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw ChromeDevToolsBrowserSemanticError.invalidEndpoint
        }

        var normalized = components
        normalized.path = ""
        guard let baseURL = normalized.url else {
            throw ChromeDevToolsBrowserSemanticError.invalidEndpoint
        }
        self.baseURL = baseURL
        self.versionURL = baseURL
            .appendingPathComponent("json", isDirectory: true)
            .appendingPathComponent("version", isDirectory: false)
        self.targetsURL = baseURL
            .appendingPathComponent("json", isDirectory: true)
            .appendingPathComponent("list", isDirectory: false)
    }

    static func validateDebuggerWebSocketURL(_ url: URL) throws -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "ws",
              let host = normalizedHost(components),
              loopbackHosts.contains(host),
              components.user == nil,
              components.password == nil else {
            throw ChromeDevToolsBrowserSemanticError.invalidDebuggerURL
        }
        return url
    }

    private static func normalizedHost(_ components: URLComponents) -> String? {
        guard let rawHost = components.host?.lowercased(), !rawHost.isEmpty else {
            return nil
        }
        return rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
}

struct ChromeDevToolsPageTarget: Equatable {
    let id: String
    let webSocketURL: URL
}

struct BrowserPageFocusState: Equatable {
    let isFocused: Bool
    let isVisible: Bool
}

struct BrowserSemanticViewport: Equatable {
    let width: Double
    let height: Double
}

struct ChromeDevToolsAXNode: Equatable {
    let backendNodeID: Int
    let role: String
    let isFocused: Bool
    let isSelected: Bool?
    let isEnabled: Bool
}

protocol ChromeDevToolsBrowserSemanticClient: AnyObject {
    func browserProcessID() async throws -> Int32
    func pageTargets() async throws -> [ChromeDevToolsPageTarget]
    func focusState(for target: ChromeDevToolsPageTarget) async throws -> BrowserPageFocusState
    func windowBounds(for target: ChromeDevToolsPageTarget) async throws -> BrowserSemanticWindowBounds
    func viewport(for target: ChromeDevToolsPageTarget) async throws -> BrowserSemanticViewport
    func accessibilityNodes(for target: ChromeDevToolsPageTarget) async throws -> [ChromeDevToolsAXNode]
    func contentQuad(backendNodeID: Int, for target: ChromeDevToolsPageTarget) async throws -> [Double]?
}

public final class ChromeDevToolsBrowserSemanticObserver: BrowserSemanticObserving {
    private let client: ChromeDevToolsBrowserSemanticClient
    private let maximumElementCount: Int
    private let windowTolerance: Double

    public convenience init(
        endpoint: URL,
        maximumElementCount: Int = 24,
        windowTolerance: Double = 8,
        timeout: TimeInterval = 2.0
    ) throws {
        let endpoint = try ChromeDevToolsEndpoint(url: endpoint)
        let client = URLSessionChromeDevToolsBrowserSemanticClient(
            endpoint: endpoint,
            timeout: timeout
        )
        self.init(
            client: client,
            maximumElementCount: maximumElementCount,
            windowTolerance: windowTolerance
        )
    }

    init(
        client: ChromeDevToolsBrowserSemanticClient,
        maximumElementCount: Int = 24,
        windowTolerance: Double = 8
    ) {
        self.client = client
        self.maximumElementCount = max(1, min(maximumElementCount, 48))
        self.windowTolerance = max(0, windowTolerance)
    }

    public func observe(
        target: ScreenFrame,
        stateVersion: UInt64
    ) async throws -> BrowserSemanticSnapshot? {
        guard let targetProcessID = target.targetProcessID else { return nil }
        guard try await client.browserProcessID() == targetProcessID else { return nil }

        let targets = try await client.pageTargets()
        guard !targets.isEmpty else { return nil }

        var focusedTargets: [ChromeDevToolsPageTarget] = []
        focusedTargets.reserveCapacity(1)

        for candidate in targets.prefix(32) {
            let focus = try await client.focusState(for: candidate)
            if focus.isFocused && focus.isVisible {
                focusedTargets.append(candidate)
                if focusedTargets.count > 1 {
                    return nil
                }
            }
        }

        guard let focusedTarget = focusedTargets.first else { return nil }
        let observedWindow = try await client.windowBounds(for: focusedTarget)
        let capturedWindow = BrowserSemanticWindowBounds(target.screenBounds)
        guard observedWindow.approximatelyEquals(
            capturedWindow,
            tolerance: windowTolerance
        ) else {
            return nil
        }

        let viewport = try await client.viewport(for: focusedTarget)
        guard viewport.width.isFinite,
              viewport.height.isFinite,
              viewport.width > 0,
              viewport.height > 0 else {
            return nil
        }

        let nodes = try await client.accessibilityNodes(for: focusedTarget)
        var elements: [BrowserSemanticElementHint] = []
        elements.reserveCapacity(min(maximumElementCount, nodes.count))

        for node in nodes {
            guard elements.count < maximumElementCount else { break }
            guard let role = Self.role(from: node.role) else { continue }
            guard let quad = try await client.contentQuad(
                backendNodeID: node.backendNodeID,
                for: focusedTarget
            ), let bounds = Self.normalizedBounds(
                quad: quad,
                viewport: viewport
            ) else {
                continue
            }

            elements.append(
                BrowserSemanticElementHint(
                    role: role,
                    bounds: bounds,
                    isFocused: node.isFocused,
                    isSelected: node.isSelected,
                    isEnabled: node.isEnabled
                )
            )
        }

        return BrowserSemanticSnapshot(
            stateVersion: stateVersion,
            processID: targetProcessID,
            windowBounds: observedWindow,
            viewportWidth: viewport.width,
            viewportHeight: viewport.height,
            elements: elements
        )
    }

    private static func role(from rawRole: String) -> BrowserSemanticRole? {
        switch rawRole.lowercased() {
        case "button": return .button
        case "checkbox": return .checkBox
        case "radio", "radiobutton": return .radioButton
        case "textbox", "textfield", "searchbox": return .textField
        case "link": return .link
        case "combobox": return .comboBox
        case "listbox": return .listBox
        case "option": return .option
        case "menuitem", "menuitemcheckbox", "menuitemradio": return .menuItem
        case "tab": return .tab
        case "switch": return .switchControl
        default: return nil
        }
    }

    private static func normalizedBounds(
        quad: [Double],
        viewport: BrowserSemanticViewport
    ) -> BrowserSemanticNormalizedBounds? {
        guard quad.count >= 8, quad.count.isMultiple(of: 2) else { return nil }
        let xs = stride(from: 0, to: quad.count, by: 2).map { quad[$0] }
        let ys = stride(from: 1, to: quad.count, by: 2).map { quad[$0] }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max(),
              minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite,
              maxX > minX, maxY > minY else {
            return nil
        }

        let bounds = BrowserSemanticNormalizedBounds(
            x: minX / viewport.width,
            y: minY / viewport.height,
            width: (maxX - minX) / viewport.width,
            height: (maxY - minY) / viewport.height
        ).clamped()
        return bounds.isMeaningful ? bounds : nil
    }
}

private final class URLSessionChromeDevToolsBrowserSemanticClient: ChromeDevToolsBrowserSemanticClient {
    private let endpoint: ChromeDevToolsEndpoint
    private let transport: ChromeDevToolsTransport
    private let maximumHTTPBytes = 2_000_000
    private let accessibilityDepth = 8

    init(endpoint: ChromeDevToolsEndpoint, timeout: TimeInterval) {
        self.endpoint = endpoint
        self.transport = ChromeDevToolsTransport(timeout: timeout)
    }

    func browserProcessID() async throws -> Int32 {
        let browserSocket = try await browserWebSocketURL()
        let result = try await transport.command(
            method: "SystemInfo.getProcessInfo",
            params: [:],
            webSocketURL: browserSocket
        )
        guard let processInfo = result["processInfo"] as? [[String: Any]] else {
            throw ChromeDevToolsBrowserSemanticError.invalidResponse
        }
        let browserIDs = processInfo.compactMap { process -> Int32? in
            guard (process["type"] as? String)?.lowercased() == "browser",
                  let number = process["id"] as? NSNumber else {
                return nil
            }
            let value = number.int64Value
            guard value > 0, value <= Int64(Int32.max) else { return nil }
            return Int32(value)
        }
        guard browserIDs.count == 1, let processID = browserIDs.first else {
            throw ChromeDevToolsBrowserSemanticError.missingBrowserProcess
        }
        return processID
    }

    func pageTargets() async throws -> [ChromeDevToolsPageTarget] {
        let data = try await transport.get(endpoint.targetsURL, maximumBytes: maximumHTTPBytes)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ChromeDevToolsBrowserSemanticError.invalidJSON
        }
        return try root.compactMap { item in
            guard (item["type"] as? String)?.lowercased() == "page",
                  let id = item["id"] as? String,
                  !id.isEmpty,
                  let rawURL = item["webSocketDebuggerUrl"] as? String,
                  let url = URL(string: rawURL) else {
                return nil
            }
            return ChromeDevToolsPageTarget(
                id: id,
                webSocketURL: try ChromeDevToolsEndpoint.validateDebuggerWebSocketURL(url)
            )
        }
    }

    func focusState(for target: ChromeDevToolsPageTarget) async throws -> BrowserPageFocusState {
        let expression = "(()=>({focused:Document.prototype.hasFocus.call(document),visibility:document.visibilityState}))()"
        let result = try await transport.command(
            method: "Runtime.evaluate",
            params: [
                "expression": expression,
                "returnByValue": true,
                "silent": true,
                "awaitPromise": false,
            ],
            webSocketURL: target.webSocketURL
        )
        guard let remote = result["result"] as? [String: Any],
              let value = remote["value"] as? [String: Any],
              let focused = value["focused"] as? Bool,
              let visibility = value["visibility"] as? String else {
            throw ChromeDevToolsBrowserSemanticError.invalidResponse
        }
        return BrowserPageFocusState(
            isFocused: focused,
            isVisible: visibility == "visible"
        )
    }

    func windowBounds(for target: ChromeDevToolsPageTarget) async throws -> BrowserSemanticWindowBounds {
        let browserSocket = try await browserWebSocketURL()
        let result = try await transport.command(
            method: "Browser.getWindowForTarget",
            params: ["targetId": target.id],
            webSocketURL: browserSocket
        )
        guard let bounds = result["bounds"] as? [String: Any],
              let left = Self.double(bounds["left"]),
              let top = Self.double(bounds["top"]),
              let width = Self.double(bounds["width"]),
              let height = Self.double(bounds["height"]),
              width > 0,
              height > 0 else {
            throw ChromeDevToolsBrowserSemanticError.invalidResponse
        }
        return BrowserSemanticWindowBounds(
            x: left,
            y: top,
            width: width,
            height: height
        )
    }

    func viewport(for target: ChromeDevToolsPageTarget) async throws -> BrowserSemanticViewport {
        let result = try await transport.command(
            method: "Page.getLayoutMetrics",
            params: [:],
            webSocketURL: target.webSocketURL
        )
        let viewport = (result["cssVisualViewport"] as? [String: Any])
            ?? (result["cssLayoutViewport"] as? [String: Any])
        guard let viewport,
              let width = Self.double(viewport["clientWidth"]),
              let height = Self.double(viewport["clientHeight"]),
              width > 0,
              height > 0 else {
            throw ChromeDevToolsBrowserSemanticError.invalidResponse
        }
        return BrowserSemanticViewport(width: width, height: height)
    }

    func accessibilityNodes(for target: ChromeDevToolsPageTarget) async throws -> [ChromeDevToolsAXNode] {
        let result = try await transport.command(
            method: "Accessibility.getFullAXTree",
            params: ["depth": accessibilityDepth],
            webSocketURL: target.webSocketURL
        )
        guard let nodes = result["nodes"] as? [[String: Any]] else {
            throw ChromeDevToolsBrowserSemanticError.invalidResponse
        }

        return nodes.compactMap { node in
            guard (node["ignored"] as? Bool) != true,
                  let backendNumber = node["backendDOMNodeId"] as? NSNumber,
                  backendNumber.intValue > 0,
                  let roleObject = node["role"] as? [String: Any],
                  let role = roleObject["value"] as? String else {
                return nil
            }

            let properties = node["properties"] as? [[String: Any]] ?? []
            let focused = Self.booleanProperty("focused", in: properties) ?? false
            let selected = Self.booleanProperty("selected", in: properties)
                ?? Self.booleanProperty("checked", in: properties)
            let disabled = Self.booleanProperty("disabled", in: properties) ?? false

            return ChromeDevToolsAXNode(
                backendNodeID: backendNumber.intValue,
                role: role,
                isFocused: focused,
                isSelected: selected,
                isEnabled: !disabled
            )
        }
    }

    func contentQuad(backendNodeID: Int, for target: ChromeDevToolsPageTarget) async throws -> [Double]? {
        let result = try await transport.command(
            method: "DOM.getContentQuads",
            params: ["backendNodeId": backendNodeID],
            webSocketURL: target.webSocketURL
        )
        guard let quads = result["quads"] as? [[NSNumber]],
              let first = quads.first else {
            return nil
        }
        return first.map(\.doubleValue)
    }

    private func browserWebSocketURL() async throws -> URL {
        let data = try await transport.get(endpoint.versionURL, maximumBytes: maximumHTTPBytes)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawURL = root["webSocketDebuggerUrl"] as? String,
              let url = URL(string: rawURL) else {
            throw ChromeDevToolsBrowserSemanticError.invalidJSON
        }
        return try ChromeDevToolsEndpoint.validateDebuggerWebSocketURL(url)
    }

    private static func booleanProperty(
        _ name: String,
        in properties: [[String: Any]]
    ) -> Bool? {
        guard let property = properties.first(where: { ($0["name"] as? String) == name }),
              let valueObject = property["value"] as? [String: Any] else {
            return nil
        }
        if let value = valueObject["value"] as? Bool {
            return value
        }
        if let value = valueObject["value"] as? String {
            switch value.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        return nil
    }
}

final class ChromeDevToolsTransport {
    private let session: URLSession
    private let timeoutNanoseconds: UInt64
    private let commandIDLock = NSLock()
    private var nextCommandID = 1

    private static let readOnlyMethods: Set<String> = [
        "SystemInfo.getProcessInfo",
        "Runtime.evaluate",
        "Browser.getWindowForTarget",
        "Page.getLayoutMetrics",
        "Accessibility.getFullAXTree",
        "DOM.getContentQuads",
    ]

    init(timeout: TimeInterval) {
        let safeTimeout = min(10, max(0.25, timeout))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = safeTimeout
        configuration.timeoutIntervalForResource = safeTimeout
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
        self.timeoutNanoseconds = UInt64(safeTimeout * 1_000_000_000)
    }

    static func isAllowedReadOnlyMethod(_ method: String) -> Bool {
        readOnlyMethods.contains(method)
    }

    func get(_ url: URL, maximumBytes: Int) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw ChromeDevToolsBrowserSemanticError.invalidHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ChromeDevToolsBrowserSemanticError.httpStatus(http.statusCode)
        }
        guard data.count <= maximumBytes else {
            throw ChromeDevToolsBrowserSemanticError.responseTooLarge
        }
        return data
    }

    func command(
        method: String,
        params: [String: Any],
        webSocketURL: URL
    ) async throws -> [String: Any] {
        guard Self.isAllowedReadOnlyMethod(method) else {
            throw ChromeDevToolsBrowserSemanticError.protocolError("method_not_allowed")
        }
        _ = try ChromeDevToolsEndpoint.validateDebuggerWebSocketURL(webSocketURL)

        let commandID = allocateCommandID()
        let payload: [String: Any] = [
            "id": commandID,
            "method": method,
            "params": params,
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        guard let payloadString = String(data: payloadData, encoding: .utf8) else {
            throw ChromeDevToolsBrowserSemanticError.invalidJSON
        }

        let task = session.webSocketTask(with: webSocketURL)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        try await task.send(.string(payloadString))

        for _ in 0..<16 {
            let message = try await receive(task)
            let data: Data
            switch message {
            case .string(let string):
                data = Data(string.utf8)
            case .data(let raw):
                data = raw
            @unknown default:
                throw ChromeDevToolsBrowserSemanticError.invalidResponse
            }

            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ChromeDevToolsBrowserSemanticError.invalidJSON
            }
            guard let responseID = root["id"] as? NSNumber,
                  responseID.intValue == commandID else {
                continue
            }
            if let error = root["error"] as? [String: Any] {
                let message = (error["message"] as? String) ?? "unknown_error"
                throw ChromeDevToolsBrowserSemanticError.protocolError(message)
            }
            guard let result = root["result"] as? [String: Any] else {
                throw ChromeDevToolsBrowserSemanticError.invalidResponse
            }
            return result
        }

        throw ChromeDevToolsBrowserSemanticError.invalidResponse
    }

    private func allocateCommandID() -> Int {
        commandIDLock.lock()
        defer { commandIDLock.unlock() }
        let result = nextCommandID
        nextCommandID = nextCommandID == Int.max ? 1 : nextCommandID + 1
        return result
    }

    private func receive(
        _ task: URLSessionWebSocketTask
    ) async throws -> URLSessionWebSocketTask.Message {
        let timeoutNanoseconds = self.timeoutNanoseconds
        return try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask {
                try await task.receive()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw ChromeDevToolsBrowserSemanticError.timeout
            }
            guard let first = try await group.next() else {
                throw ChromeDevToolsBrowserSemanticError.invalidResponse
            }
            group.cancelAll()
            return first
        }
    }
}

import XCTest
import CoreGraphics
@testable import ExamPilotCore

final class ChromeDevToolsBrowserSemanticObserverTests: XCTestCase {
    func testRejectsDifferentBrowserProcessBeforeInspectingTargets() async throws {
        let client = StubChromeDevToolsSemanticClient(
            browserProcessID: 99,
            targets: [makeTarget("page-1")]
        )
        let observer = ChromeDevToolsBrowserSemanticObserver(client: client)

        let snapshot = try await observer.observe(
            target: makeFrame(processID: 42),
            stateVersion: 5
        )

        XCTAssertNil(snapshot)
        XCTAssertEqual(client.focusChecks, 0)
        XCTAssertEqual(client.treeRequests, 0)
    }

    func testRejectsAmbiguousFocusedVisiblePageTargets() async throws {
        let first = makeTarget("page-1")
        let second = makeTarget("page-2")
        let client = StubChromeDevToolsSemanticClient(
            browserProcessID: 42,
            targets: [first, second],
            focusStates: [
                first.id: BrowserPageFocusState(isFocused: true, isVisible: true),
                second.id: BrowserPageFocusState(isFocused: true, isVisible: true),
            ]
        )
        let observer = ChromeDevToolsBrowserSemanticObserver(client: client)

        let snapshot = try await observer.observe(
            target: makeFrame(processID: 42),
            stateVersion: 5
        )

        XCTAssertNil(snapshot)
        XCTAssertEqual(client.treeRequests, 0)
    }

    func testRejectsFocusedTargetInDifferentBrowserWindow() async throws {
        let target = makeTarget("page-1")
        let client = StubChromeDevToolsSemanticClient(
            browserProcessID: 42,
            targets: [target],
            focusStates: [target.id: BrowserPageFocusState(isFocused: true, isVisible: true)],
            windowBounds: [target.id: BrowserSemanticWindowBounds(x: 400, y: 400, width: 500, height: 400)]
        )
        let observer = ChromeDevToolsBrowserSemanticObserver(client: client)

        let snapshot = try await observer.observe(
            target: makeFrame(processID: 42),
            stateVersion: 5
        )

        XCTAssertNil(snapshot)
        XCTAssertEqual(client.treeRequests, 0)
    }

    func testBuildsBoundedRoleStateHintsWithViewportNormalizedQuads() async throws {
        let target = makeTarget("page-1")
        let client = StubChromeDevToolsSemanticClient(
            browserProcessID: 42,
            targets: [target],
            focusStates: [target.id: BrowserPageFocusState(isFocused: true, isVisible: true)],
            windowBounds: [target.id: BrowserSemanticWindowBounds(x: 10, y: 20, width: 800, height: 600)],
            viewport: [target.id: BrowserSemanticViewport(width: 1000, height: 500)],
            nodes: [
                ChromeDevToolsAXNode(
                    backendNodeID: 10,
                    role: "button",
                    isFocused: true,
                    isSelected: nil,
                    isEnabled: true
                ),
                ChromeDevToolsAXNode(
                    backendNodeID: 11,
                    role: "StaticText",
                    isFocused: false,
                    isSelected: nil,
                    isEnabled: true
                ),
                ChromeDevToolsAXNode(
                    backendNodeID: 12,
                    role: "radio",
                    isFocused: false,
                    isSelected: true,
                    isEnabled: true
                ),
            ],
            quads: [
                10: [100, 50, 300, 50, 300, 100, 100, 100],
                12: [500, 250, 600, 250, 600, 300, 500, 300],
            ]
        )
        let observer = ChromeDevToolsBrowserSemanticObserver(client: client, maximumElementCount: 24)

        let observed = try await observer.observe(
            target: makeFrame(processID: 42),
            stateVersion: 5
        )
        let snapshot = try XCTUnwrap(observed)

        XCTAssertEqual(snapshot.stateVersion, 5)
        XCTAssertEqual(snapshot.processID, 42)
        XCTAssertEqual(snapshot.elements.count, 2)
        XCTAssertEqual(snapshot.elements[0].role, .button)
        XCTAssertEqual(snapshot.elements[0].bounds.x, 0.1, accuracy: 0.0001)
        XCTAssertEqual(snapshot.elements[0].bounds.y, 0.1, accuracy: 0.0001)
        XCTAssertEqual(snapshot.elements[0].bounds.width, 0.2, accuracy: 0.0001)
        XCTAssertEqual(snapshot.elements[0].bounds.height, 0.1, accuracy: 0.0001)
        XCTAssertEqual(snapshot.elements[1].role, .radioButton)
        XCTAssertEqual(snapshot.elements[1].isSelected, true)
        XCTAssertFalse(client.requestedBackendNodeIDs.contains(11))
    }

    func testBoundsNodeWorkEvenWhenTreeIsLarge() async throws {
        let target = makeTarget("page-1")
        let nodes = (0..<100).map { index in
            ChromeDevToolsAXNode(
                backendNodeID: index + 1,
                role: "button",
                isFocused: false,
                isSelected: nil,
                isEnabled: true
            )
        }
        let quads = Dictionary(uniqueKeysWithValues: (1...100).map { id in
            (id, [10.0, 10.0, 20.0, 10.0, 20.0, 20.0, 10.0, 20.0])
        })
        let client = StubChromeDevToolsSemanticClient(
            browserProcessID: 42,
            targets: [target],
            focusStates: [target.id: BrowserPageFocusState(isFocused: true, isVisible: true)],
            windowBounds: [target.id: BrowserSemanticWindowBounds(x: 10, y: 20, width: 800, height: 600)],
            viewport: [target.id: BrowserSemanticViewport(width: 1000, height: 500)],
            nodes: nodes,
            quads: quads
        )
        let observer = ChromeDevToolsBrowserSemanticObserver(client: client, maximumElementCount: 12)

        let observed = try await observer.observe(
            target: makeFrame(processID: 42),
            stateVersion: 5
        )
        let snapshot = try XCTUnwrap(observed)

        XCTAssertEqual(snapshot.elements.count, 12)
        XCTAssertEqual(client.requestedBackendNodeIDs.count, 12)
    }

    private func makeTarget(_ id: String) -> ChromeDevToolsPageTarget {
        ChromeDevToolsPageTarget(
            id: id,
            webSocketURL: URL(string: "ws://127.0.0.1:9222/devtools/page/\(id)")!
        )
    }

    private func makeFrame(processID: Int32) -> ScreenFrame {
        let context = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ScreenFrame(
            image: context.makeImage()!,
            jpegData: Data([1, 2, 3]),
            screenBounds: CGRect(x: 10, y: 20, width: 800, height: 600),
            targetProcessID: processID
        )
    }
}

private final class StubChromeDevToolsSemanticClient: ChromeDevToolsBrowserSemanticClient {
    let configuredBrowserProcessID: Int32
    let configuredTargets: [ChromeDevToolsPageTarget]
    let configuredFocusStates: [String: BrowserPageFocusState]
    let configuredWindowBounds: [String: BrowserSemanticWindowBounds]
    let configuredViewport: [String: BrowserSemanticViewport]
    let configuredNodes: [ChromeDevToolsAXNode]
    let configuredQuads: [Int: [Double]]

    private(set) var focusChecks = 0
    private(set) var treeRequests = 0
    private(set) var requestedBackendNodeIDs: [Int] = []

    init(
        browserProcessID: Int32,
        targets: [ChromeDevToolsPageTarget],
        focusStates: [String: BrowserPageFocusState] = [:],
        windowBounds: [String: BrowserSemanticWindowBounds] = [:],
        viewport: [String: BrowserSemanticViewport] = [:],
        nodes: [ChromeDevToolsAXNode] = [],
        quads: [Int: [Double]] = [:]
    ) {
        self.configuredBrowserProcessID = browserProcessID
        self.configuredTargets = targets
        self.configuredFocusStates = focusStates
        self.configuredWindowBounds = windowBounds
        self.configuredViewport = viewport
        self.configuredNodes = nodes
        self.configuredQuads = quads
    }

    func browserProcessID() async throws -> Int32 {
        configuredBrowserProcessID
    }

    func pageTargets() async throws -> [ChromeDevToolsPageTarget] {
        configuredTargets
    }

    func focusState(for target: ChromeDevToolsPageTarget) async throws -> BrowserPageFocusState {
        focusChecks += 1
        return configuredFocusStates[target.id] ?? BrowserPageFocusState(isFocused: false, isVisible: false)
    }

    func windowBounds(for target: ChromeDevToolsPageTarget) async throws -> BrowserSemanticWindowBounds {
        configuredWindowBounds[target.id] ?? BrowserSemanticWindowBounds(x: 10, y: 20, width: 800, height: 600)
    }

    func viewport(for target: ChromeDevToolsPageTarget) async throws -> BrowserSemanticViewport {
        configuredViewport[target.id] ?? BrowserSemanticViewport(width: 1000, height: 500)
    }

    func accessibilityNodes(for target: ChromeDevToolsPageTarget) async throws -> [ChromeDevToolsAXNode] {
        treeRequests += 1
        return configuredNodes
    }

    func contentQuad(backendNodeID: Int, for target: ChromeDevToolsPageTarget) async throws -> [Double]? {
        requestedBackendNodeIDs.append(backendNodeID)
        return configuredQuads[backendNodeID]
    }
}

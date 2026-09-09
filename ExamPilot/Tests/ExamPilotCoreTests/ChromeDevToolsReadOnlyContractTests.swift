import XCTest
@testable import ExamPilotCore

final class ChromeDevToolsReadOnlyContractTests: XCTestCase {
    func testAllowsOnlySliceEightReadOnlyMethods() {
        let allowed = [
            "SystemInfo.getProcessInfo",
            "Runtime.evaluate",
            "Browser.getWindowForTarget",
            "Page.getLayoutMetrics",
            "Accessibility.getFullAXTree",
            "DOM.getContentQuads",
        ]

        for method in allowed {
            XCTAssertTrue(
                ChromeDevToolsTransport.isAllowedReadOnlyMethod(method),
                "Expected read-only CDP method to be allowed: \(method)"
            )
        }
    }

    func testRejectsMutationAndNavigationMethods() {
        let forbidden = [
            "Page.navigate",
            "Page.reload",
            "Input.dispatchMouseEvent",
            "Input.dispatchKeyEvent",
            "Input.insertText",
            "DOM.focus",
            "DOM.setAttributeValue",
            "Browser.setWindowBounds",
            "Browser.setDownloadBehavior",
            "Target.activateTarget",
            "Runtime.callFunctionOn",
        ]

        for method in forbidden {
            XCTAssertFalse(
                ChromeDevToolsTransport.isAllowedReadOnlyMethod(method),
                "Mutation-capable CDP method must remain forbidden: \(method)"
            )
        }
    }
}

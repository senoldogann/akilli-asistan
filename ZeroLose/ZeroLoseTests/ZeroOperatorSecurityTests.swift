import XCTest
@testable import ZeroLose

@MainActor
final class ZeroOperatorSecurityTests: XCTestCase {
    private let unsafeShellCommandsFlag = "allowUnsafeShellCommands"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: unsafeShellCommandsFlag)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: unsafeShellCommandsFlag)
        super.tearDown()
    }

    func testExecuteShellBlockedWhenUnsafeModeIsDisabled() async {
        let operatorService = ZeroOperator()

        do {
            _ = try await operatorService.executeShell("open https://example.com")
            XCTFail("Expected unauthorized error when unsafe shell mode is disabled.")
        } catch ZeroOperator.OperatorError.unauthorized {
            // Expected
        } catch {
            XCTFail("Expected unauthorized error, got: \(error)")
        }
    }

    func testExecuteShellBlocksNonAllowlistedCommandEvenWhenUnsafeModeEnabled() async {
        UserDefaults.standard.set(true, forKey: unsafeShellCommandsFlag)
        let operatorService = ZeroOperator()

        do {
            _ = try await operatorService.executeShell("echo hello")
            XCTFail("Expected unauthorized error for non-allowlisted shell command.")
        } catch ZeroOperator.OperatorError.unauthorized {
            // Expected
        } catch {
            XCTFail("Expected unauthorized error, got: \(error)")
        }
    }
}

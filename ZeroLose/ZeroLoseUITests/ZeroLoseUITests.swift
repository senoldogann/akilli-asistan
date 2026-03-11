//
//  ZeroLoseUITests.swift
//  ZeroLoseUITests
//
//  Created by dogan on 20.1.2026.
//

import XCTest

final class ZeroLoseUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchesInUITestMode() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing")
        app.launch()

        XCTAssertTrue(
            app.staticTexts["ZeroLose UI Test Mode"].waitForExistence(timeout: 5),
            "UI test harness root view did not appear."
        )
    }
}

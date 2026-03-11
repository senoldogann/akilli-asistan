//
//  ZeroLoseUITestsLaunchTests.swift
//  ZeroLoseUITests
//
//  Created by dogan on 20.1.2026.
//

import XCTest

final class ZeroLoseUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing")
        app.launch()

        XCTAssertTrue(
            app.staticTexts["ZeroLose UI Test Mode"].waitForExistence(timeout: 5),
            "UI test harness root view did not appear."
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

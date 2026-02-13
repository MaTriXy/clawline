//
//  ClawlineUITests.swift
//  ClawlineUITests
//
//  Created by Mike Manzano on 1/7/26.
//

import XCTest

final class ClawlineUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    func testScrollButtonDragMovesAndPersistsDetent() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-auth.token", "debug-token",
            "-auth.userId", "debug-user",
            "-auth.isAdmin", "YES",
            "-provider.baseURL", "ws://127.0.0.1:8080",
            "--debug-force-scroll-button",
        ]
        app.launch()

        let button = app.buttons["scroll_to_bottom_button"]
        XCTAssertTrue(button.waitForExistence(timeout: 6), "Expected debug-forced scroll button to exist")

        let startFrame = button.frame
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: startFrame.midX, dy: startFrame.midY))
        let end = start.withOffset(CGVector(dx: 140, dy: 0))

        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(1) // allow spring settle to complete before asserting frame.

        let draggedFrame = button.frame
        XCTAssertGreaterThan(
            draggedFrame.midX,
            startFrame.midX + 24,
            "Scroll button should move horizontally after drag gesture"
        )

        app.terminate()
        app.launch()
        XCTAssertTrue(button.waitForExistence(timeout: 6))
        sleep(1)
        let relaunchedFrame = button.frame
        XCTAssertGreaterThan(
            relaunchedFrame.midX,
            startFrame.midX + 24,
            "Detent should persist across relaunch"
        )
    }
}

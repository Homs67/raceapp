//
//  raceAppUITests.swift
//  raceAppUITests
//
//  Created by Alex Khomutov on 7/7/26.
//

import XCTest

final class raceAppUITests: XCTestCase {

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
    func testRecordingSurvivesBackgrounding() throws {
        addUIInterruptionMonitor(withDescription: "System permissions") { alert in
            for title in ["Allow While Using App", "Allow", "Continue"] {
                let button = alert.buttons[title]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }

        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-record"]
        app.launch()
        app.tap() // lets the interruption monitor handle first-run permissions

        let stopButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Stop Recording'")
        ).firstMatch
        XCTAssertTrue(stopButton.waitForExistence(timeout: 10))

        XCUIDevice.shared.press(.home)
        sleep(10)
        app.activate()

        XCTAssertTrue(stopButton.waitForExistence(timeout: 5),
                      "an active recording must survive normal backgrounding")
        stopButton.tap()
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}

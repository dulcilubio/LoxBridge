//
//  LoxBridgeUITests.swift
//  LoxBridgeUITests
//
//  Fastlane snapshot test — captures App Store screenshots automatically.
//  Run via: LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 fastlane snapshot
//

import XCTest

// @MainActor ensures all methods (including setUp) run on the main thread,
// which is required since setupSnapshot() and XCUIApplication are main-actor isolated.
@MainActor
final class LoxBridgeUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        app = XCUIApplication()

        // Skip onboarding so we land directly on the main tab view.
        app.launchArguments += ["-onboardingCompleted", "1", "-SCREENSHOT_MODE", "1"]

        setupSnapshot(app)
        app.launch()
    }

    // MARK: - Screenshot tests
    // Prefixed with numbers so they run — and appear in App Store Connect — in order.

    /// Screenshot 1 — Home tab
    func test01_Home() throws {
        let homeTab = app.tabBars.buttons["Home"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 5))
        homeTab.tap()
        snapshot("01_Home")
    }

    /// Screenshot 2 — Routes tab (list of recorded routes)
    func test02_Routes() throws {
        let routesTab = app.tabBars.buttons["Routes"]
        XCTAssertTrue(routesTab.waitForExistence(timeout: 5))
        routesTab.tap()
        sleep(1)
        snapshot("02_Routes")
    }

    /// Screenshot 3 — Settings tab
    func test03_Settings() throws {
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()
        sleep(1)
        snapshot("03_Settings")
    }
}

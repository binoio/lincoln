import XCTest
@testable import Lincoln

@MainActor
final class SettingsManagerTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = TestFixtures.isolatedDefaults()
    }

    private func make() -> SettingsManager {
        let settings = SettingsManager(defaults: defaults, loginItem: FakeLoginItem())
        settings.appliesActivationPolicy = false
        return settings
    }

    func testDefaults() {
        let settings = make()
        XCTAssertTrue(settings.showMenuBarItem)
        XCTAssertFalse(settings.hideDockIcon)
        XCTAssertTrue(settings.restoreConnectionsOnLaunch)
        XCTAssertTrue(settings.notificationsEnabled)
        XCTAssertEqual(settings.sshExecutable, "/usr/bin/ssh")
        XCTAssertEqual(settings.extraPath, SettingsManager.defaultExtraPath)
        XCTAssertEqual(settings.serverAliveInterval, 30)
        XCTAssertEqual(settings.serverAliveCountMax, 3)
        XCTAssertFalse(settings.launchAtLogin)
    }

    func testPersistenceRoundTrip() {
        let settings = make()
        settings.hideDockIcon = true
        settings.restoreConnectionsOnLaunch = false
        settings.sshExecutable = "/opt/homebrew/bin/ssh"
        settings.serverAliveInterval = 15
        settings.sshAuthSock = "~/.ssh/agent/sock"

        let reloaded = make()
        XCTAssertTrue(reloaded.hideDockIcon)
        XCTAssertFalse(reloaded.restoreConnectionsOnLaunch)
        XCTAssertEqual(reloaded.sshExecutable, "/opt/homebrew/bin/ssh")
        XCTAssertEqual(reloaded.serverAliveInterval, 15)
        XCTAssertEqual(reloaded.sshAuthSock, "~/.ssh/agent/sock")
    }

    func testHidingDockForcesMenuBarOn() {
        let settings = make()
        settings.showMenuBarItem = false
        settings.hideDockIcon = true
        XCTAssertTrue(settings.showMenuBarItem)
        XCTAssertTrue(settings.hideDockIcon)

        settings.showMenuBarItem = false
        XCTAssertFalse(settings.hideDockIcon, "turning the menu bar off brings the Dock icon back")
    }

    func testInconsistentStoredStateIsRepaired() {
        defaults.set(false, forKey: SettingsManager.Key.showMenuBarItem)
        defaults.set(true, forKey: SettingsManager.Key.hideDockIcon)
        let settings = make()
        XCTAssertFalse(settings.hideDockIcon)
    }

    func testResetSSHDefaults() {
        let settings = make()
        settings.sshExecutable = "/x"
        settings.serverAliveCountMax = 9
        settings.resetSSHDefaults()
        XCTAssertEqual(settings.sshExecutable, "/usr/bin/ssh")
        XCTAssertEqual(settings.serverAliveCountMax, 3)
    }
}

import XCTest
@testable import Lincoln

@MainActor
final class TerminalLauncherTests: XCTestCase {
    func testScriptIsWrittenExecutableAndPrivate() throws {
        let directory = TestFixtures.temporaryDirectory("commands")
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = TerminalAppLauncher(scriptsDirectory: directory)
        let url = try launcher.write(script: "#!/bin/zsh\necho hi\n", name: "Gateway SOCKS/tg")
        XCTAssertEqual(url.lastPathComponent, "Gateway-SOCKS-tg.command")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "#!/bin/zsh\necho hi\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o700)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o700)
    }

    func testFileNames() {
        XCTAssertEqual(TerminalAppLauncher.fileName(for: "tg"), "tg")
        XCTAssertEqual(TerminalAppLauncher.fileName(for: "  ///  "), "tunnel")
        XCTAssertEqual(TerminalAppLauncher.fileName(for: "Gateway (SOCKS)"), "Gateway--SOCKS")
    }

    func testTerminalAppIsInstalled() {
        XCTAssertNotNil(NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalAppLauncher.terminalBundleIdentifier))
    }
}

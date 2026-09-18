import Foundation
import XCTest
@testable import LincolnCore

enum TestSupport {
    static var fixturesURL: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// Copies the fixtures into a temporary ~/.ssh so Include resolution
    /// (relative to ~/.ssh, ~ expansion, globs) is exercised for real.
    static func makeTemporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lincoln-tests-\(UUID().uuidString)", isDirectory: true)
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        for name in ["config", "config_local"] {
            try FileManager.default.copyItem(at: fixturesURL.appendingPathComponent(name), to: ssh.appendingPathComponent(name))
        }
        try FileManager.default.copyItem(at: fixturesURL.appendingPathComponent("conf.d"), to: ssh.appendingPathComponent("conf.d"))
        return home
    }

    static func sampleTunnel(id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!) -> Tunnel {
        Tunnel(
            id: id,
            name: "Gateway SOCKS",
            host: "tg",
            forwards: [
                Forward(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, kind: .dynamic, listenPort: 1080),
                Forward(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!, kind: .local, listenPort: 10445, targetHost: "files.princeton.edu", targetPort: 445)
            ]
        )
    }
}

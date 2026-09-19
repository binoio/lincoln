import XCTest
import LincolnCore
@testable import Lincoln

/// The real socket server talking to the real bundled lincoln-askpass helper.
@MainActor
final class AskpassServerTests: XCTestCase {
    private var socketURL: URL!
    private var server: AskpassServer!

    override func setUp() async throws {
        socketURL = URL(fileURLWithPath: "/tmp/lincoln-ap-\(UUID().uuidString.prefix(8)).sock")
        server = AskpassServer(socketURL: socketURL)
        try server.start()
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: socketURL)
    }

    nonisolated private static func runHelper(helper: URL, socketPath: String, prompt: String, hint: String? = nil) throws -> (stdout: String, status: Int32) {
        let process = Process()
        process.executableURL = helper
        process.arguments = [prompt]
        var env = ["LINCOLN_ASKPASS_SOCKET": socketPath, "LINCOLN_ASKPASS_TUNNEL": "00000000-0000-0000-0000-000000000001"]
        if let hint = hint { env["SSH_ASKPASS_PROMPT"] = hint }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }

    private func runHelper(prompt: String, hint: String? = nil) async throws -> (stdout: String, status: Int32) {
        let helper = try XCTUnwrap(AskpassServer.helperURL, "lincoln-askpass must be embedded in the app bundle")
        let socketPath = socketURL.path
        return try await Task.detached { try AskpassServerTests.runHelper(helper: helper, socketPath: socketPath, prompt: prompt, hint: hint) }.value
    }

    func testSocketIsPrivate() throws {
        XCTAssertTrue(server.isListening)
        let attributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o600)
    }

    func testHelperRelaysPromptAndReceivesAnswer() async throws {
        let received = expectation(description: "prompt")
        var request: AskpassRequest?
        server.onPrompt = { prompt in
            request = prompt.request
            prompt.answer("1")
            received.fulfill()
        }
        let result = try await runHelper(prompt: "Passcode or option (1-2): ")
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(request, AskpassRequest(prompt: "Passcode or option (1-2): ", hint: nil, tunnelID: "00000000-0000-0000-0000-000000000001"))
        XCTAssertEqual(result.stdout, "1\n")
        XCTAssertEqual(result.status, 0)
    }

    func testHelperExitsNonZeroWhenCancelled() async throws {
        server.onPrompt = { $0.cancel() }
        let result = try await runHelper(prompt: "Are you sure you want to continue connecting (yes/no/[fingerprint])? ", hint: "confirm")
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stdout, "")
    }

    func testHelperFailsWithoutServer() async throws {
        server.stop()
        let result = try await runHelper(prompt: "x")
        XCTAssertEqual(result.status, 1)
    }
}

import XCTest
@testable import Lincoln

/// Integration: a real pty-backed child, driven the way ssh would be.
@MainActor
final class PTYProcessTests: XCTestCase {
    func testEchoAndReadLineThroughPTY() async throws {
        let process = PTYProcess(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'name: '; read x; echo \"got:$x\"; exit 7"],
            environment: ["PATH": "/bin:/usr/bin", "TERM": "dumb"]
        )
        var output = ""
        let promptSeen = expectation(description: "prompt")
        let answerSeen = expectation(description: "answer")
        let exited = expectation(description: "exit")
        // Output arrives in chunks; the same substring may be seen repeatedly.
        promptSeen.assertForOverFulfill = false
        answerSeen.assertForOverFulfill = false
        var exitStatus: Int32?
        process.onOutput = { data in
            output += String(decoding: data, as: UTF8.self)
            if output.contains("name: ") { promptSeen.fulfill() }
            if output.contains("got:lincoln") { answerSeen.fulfill() }
        }
        process.onExit = { status in
            exitStatus = status
            exited.fulfill()
        }
        try process.start()
        XCTAssertTrue(process.isRunning)
        XCTAssertGreaterThan(process.processIdentifier, 0)

        await fulfillment(of: [promptSeen], timeout: 5)
        process.write("lincoln\n")
        await fulfillment(of: [answerSeen, exited], timeout: 5)
        XCTAssertEqual(exitStatus, 7)
        XCTAssertFalse(process.isRunning)
        // The pty echoes what we typed, proving stdin is a terminal.
        XCTAssertTrue(output.contains("lincoln"))
    }

    func testChildSeesATerminal() async throws {
        let process = PTYProcess(
            executable: "/bin/sh",
            arguments: ["-c", "if [ -t 0 ] && [ -t 1 ]; then echo TTY_OK; else echo NO_TTY; fi; tty"],
            environment: ["PATH": "/bin:/usr/bin"]
        )
        var output = ""
        let exited = expectation(description: "exit")
        process.onOutput = { output += String(decoding: $0, as: UTF8.self) }
        process.onExit = { _ in exited.fulfill() }
        try process.start()
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertTrue(output.contains("TTY_OK"), output)
        XCTAssertTrue(output.contains("/dev/ttys"), output)
    }

    func testTerminateSendsSIGTERMThenSIGKILL() async throws {
        let process = PTYProcess(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; sleep 30"],
            environment: ["PATH": "/bin:/usr/bin"]
        )
        process.killGracePeriod = 0.3
        let exited = expectation(description: "exit")
        var status: Int32?
        process.onExit = { status = $0; exited.fulfill() }
        try process.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        process.terminate()
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertEqual(status, 128 + SIGKILL)
    }

    func testMissingExecutableExits127() async throws {
        let process = PTYProcess(executable: "/nonexistent/ssh", arguments: [], environment: [:])
        let exited = expectation(description: "exit")
        var status: Int32?
        process.onExit = { status = $0; exited.fulfill() }
        try process.start()
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertEqual(status, 127)
    }

    func testDoubleStartThrows() throws {
        let process = PTYProcess(executable: "/usr/bin/true", arguments: [], environment: [:])
        try process.start()
        XCTAssertThrowsError(try process.start())
    }
}

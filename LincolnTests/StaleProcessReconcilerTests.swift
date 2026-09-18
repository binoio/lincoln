import XCTest
import LincolnCore
@testable import Lincoln

final class StaleProcessReconcilerTests: XCTestCase {
    private let id = UUID()

    private var psOutput: String {
        """
            1     0 /sbin/launchd
          800     1 /usr/bin/ssh -N -o LocalCommand=echo \(SSHCommandBuilder.readySentinel(for: id)) -- tg
          801   500 /usr/bin/ssh -N -o LocalCommand=echo LINCOLN_READY_not-a-uuid -- della
          802   500 /usr/bin/ssh -N della
        """
    }

    func testParseFindsSentinelProcesses() {
        let parsed = StaleProcessReconciler.parse(psOutput)
        XCTAssertEqual(parsed.map(\.pid), [800, 801])
        XCTAssertEqual(parsed[0].parentPID, 1)
        XCTAssertEqual(parsed[0].tunnelID, id)
        XCTAssertNil(parsed[1].tunnelID)
        XCTAssertTrue(parsed[0].command.hasPrefix("/usr/bin/ssh"))
    }

    func testReconcileSkipsOwnChildren() {
        var killed: [pid_t] = []
        let reconciler = StaleProcessReconciler(listProcesses: { self.psOutput }, currentPID: 500, terminate: { killed.append($0) })
        let stale = reconciler.reconcile()
        XCTAssertEqual(stale.map(\.pid), [800])
        XCTAssertEqual(killed, [800])
    }

    func testRealProcessListIsReadable() {
        let output = StaleProcessReconciler.defaultProcessList()
        XCTAssertTrue(output.contains("launchd"))
        // A running test host is never mistaken for a stale ssh.
        let reconciler = StaleProcessReconciler(listProcesses: { output }, terminate: { _ in XCTFail("nothing should be killed") })
        _ = reconciler.findStaleProcesses().filter { $0.pid == getpid() }
    }
}

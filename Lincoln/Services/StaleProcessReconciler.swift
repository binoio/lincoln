//
//  StaleProcessReconciler.swift
//  Lincoln
//
//  A previous Lincoln that crashed or was force-quit can leave ssh children
//  behind. Every Lincoln-owned ssh carries the LINCOLN_READY_<id> sentinel in
//  its command line, so on launch we find and stop any that do not belong to
//  this process. No pid files to keep in sync; idempotent by construction.
//

import Foundation
import LincolnCore

struct StaleSSHProcess: Equatable {
    var pid: pid_t
    var parentPID: pid_t
    var tunnelID: UUID?
    var command: String
}

struct StaleProcessReconciler {
    /// Returns `ps -axo pid=,ppid=,command=` style lines. Injectable for tests.
    var listProcesses: () -> String
    var currentPID: pid_t
    var terminate: (pid_t) -> Void

    init(
        listProcesses: @escaping () -> String = StaleProcessReconciler.defaultProcessList,
        currentPID: pid_t = getpid(),
        terminate: @escaping (pid_t) -> Void = { kill($0, SIGTERM) }
    ) {
        self.listProcesses = listProcesses
        self.currentPID = currentPID
        self.terminate = terminate
    }

    static func defaultProcessList() -> String {
        SSHEnvironment.runSynchronously(executable: "/bin/ps", arguments: ["-axo", "pid=,ppid=,command="], environment: ["PATH": "/bin:/usr/bin"]).standardOutput
    }

    /// Lincoln-owned ssh processes not parented by this Lincoln.
    func findStaleProcesses() -> [StaleSSHProcess] {
        StaleProcessReconciler.parse(listProcesses()).filter { $0.parentPID != currentPID && $0.pid != currentPID }
    }

    /// Stops stale processes and returns what was stopped.
    @discardableResult
    func reconcile() -> [StaleSSHProcess] {
        let stale = findStaleProcesses()
        for process in stale {
            terminate(process.pid)
        }
        return stale
    }

    static func parse(_ output: String) -> [StaleSSHProcess] {
        output.components(separatedBy: .newlines).compactMap { line in
            guard line.contains(SSHCommandBuilder.sentinelPrefix) else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = pid_t(parts[0]), let ppid = pid_t(parts[1]) else { return nil }
            let command = String(parts[2])
            return StaleSSHProcess(pid: pid, parentPID: ppid, tunnelID: tunnelID(in: command), command: command)
        }
    }

    static func tunnelID(in command: String) -> UUID? {
        guard let range = command.range(of: SSHCommandBuilder.sentinelPrefix) else { return nil }
        let tail = command[range.upperBound...]
        let candidate = tail.prefix(36)
        return UUID(uuidString: String(candidate))
    }
}

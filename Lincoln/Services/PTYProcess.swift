//
//  PTYProcess.swift
//  Lincoln
//
//  Runs ssh under a pseudo-terminal Lincoln owns, so keyboard-interactive
//  prompts (Duo, key passphrases, host keys) reach the in-app console
//  instead of failing for lack of a tty.
//

import Foundation
import Darwin

/// A child process attached to a pty. Callbacks are delivered on the main actor.
@MainActor
protocol TunnelProcess: AnyObject {
    var onOutput: ((Data) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }
    var processIdentifier: pid_t { get }
    var isRunning: Bool { get }
    func start() throws
    func write(_ text: String)
    /// SIGTERM now, SIGKILL if the process lingers.
    func terminate()
}

@MainActor
protocol TunnelProcessFactory {
    func makeProcess(executable: String, arguments: [String], environment: [String: String]) -> TunnelProcess
}

struct PTYProcessFactory: TunnelProcessFactory {
    func makeProcess(executable: String, arguments: [String], environment: [String: String]) -> TunnelProcess {
        PTYProcess(executable: executable, arguments: arguments, environment: environment)
    }
}

enum PTYProcessError: LocalizedError {
    case forkFailed(Int32)
    case alreadyStarted

    var errorDescription: String? {
        switch self {
        case .forkFailed(let errno): return "forkpty failed: \(String(cString: strerror(errno)))"
        case .alreadyStarted: return "process already started"
        }
    }
}

@MainActor
final class PTYProcess: TunnelProcess {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    var killGracePeriod: TimeInterval = 3

    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    private(set) var processIdentifier: pid_t = 0
    private(set) var isRunning = false
    private(set) var exitStatus: Int32?

    /// Set once in start() before any dispatch source runs; read from the
    /// pty queue afterwards, so no further synchronization is needed.
    nonisolated(unsafe) private var masterFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private let queue = DispatchQueue(label: "io.binoio.Lincoln.pty", qos: .userInitiated)

    init(executable: String, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    func start() throws {
        guard processIdentifier == 0 else { throw PTYProcessError.alreadyStarted }

        // Everything the child needs is prepared before fork: only
        // async-signal-safe calls are allowed afterwards.
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        let path = strdup(executable)
        defer { free(path) }

        var master: Int32 = -1
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        let pid = forkpty(&master, nil, nil, &size)
        if pid < 0 {
            throw PTYProcessError.forkFailed(errno)
        }
        if pid == 0 {
            // Child: leave inherited descriptors behind, then exec.
            var fd: Int32 = 3
            while fd < 256 { close(fd); fd += 1 }
            Darwin.signal(SIGPIPE, SIG_DFL)
            Darwin.signal(SIGINT, SIG_DFL)
            Darwin.signal(SIGTERM, SIG_DFL)
            argv.withUnsafeBufferPointer { argvPointer in
                envp.withUnsafeBufferPointer { envpPointer in
                    _ = execve(path, argvPointer.baseAddress, envpPointer.baseAddress)
                }
            }
            _exit(127)
        }

        processIdentifier = pid
        masterFD = master
        isRunning = true
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)

        let readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        readSource.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.drainOutput()
        }
        readSource.setCancelHandler { [weak self] in
            guard let self = self else { return }
            let fd = self.masterFD
            if fd >= 0 { close(fd) }
        }
        self.readSource = readSource
        readSource.resume()

        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exitSource.setEventHandler { [weak self] in
            guard let self = self else { return }
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            let exitCode: Int32
            if (status & 0x7f) == 0 {
                exitCode = (status >> 8) & 0xff
            } else {
                exitCode = 128 + (status & 0x7f)
            }
            // Deliver output that arrived just before exit first.
            self.drainOutput(final: true)
            self.readSource?.cancel()
            self.exitSource?.cancel()
            Task { @MainActor in
                self.isRunning = false
                self.exitStatus = exitCode
                self.onExit?(exitCode)
            }
        }
        self.exitSource = exitSource
        exitSource.resume()
    }

    nonisolated private func drainOutput(final: Bool = false) {
        let fd = masterFD
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        var collected = Data()
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                collected.append(contentsOf: buffer[0..<count])
                continue
            }
            if count < 0 && errno == EINTR { continue }
            break
        }
        guard !collected.isEmpty else { return }
        Task { @MainActor in
            self.onOutput?(collected)
        }
    }

    func write(_ text: String) {
        guard isRunning, masterFD >= 0, let data = text.data(using: .utf8) else { return }
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(masterFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }

    func terminate() {
        guard isRunning, processIdentifier > 0 else { return }
        let pid = processIdentifier
        kill(pid, SIGTERM)
        let grace = killGracePeriod
        DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak self] in
            guard let self = self, self.isRunning, self.processIdentifier == pid else { return }
            kill(pid, SIGKILL)
        }
    }

    /// Sends a signal directly.
    func sendSignal(_ signalNumber: Int32) {
        guard isRunning, processIdentifier > 0 else { return }
        kill(processIdentifier, signalNumber)
    }
}

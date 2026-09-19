//
//  AskpassServer.swift
//  Lincoln
//
//  Listens on a local Unix socket for prompts relayed by the bundled
//  lincoln-askpass helper (which ssh runs via SSH_ASKPASS) and hands each
//  one to the app to answer. This is how Duo, passphrase and host-key
//  prompts reach the GUI without a terminal.
//

import Foundation
import Darwin
import LincolnCore

struct AskpassRequest: Codable, Equatable {
    var prompt: String
    var hint: String?
    var tunnelID: String?
}

struct AskpassReply: Codable, Equatable {
    var answer: String?
    var cancelled: Bool
}

/// A prompt waiting for an answer. `respond` may be called once.
@MainActor
final class PendingPrompt: Identifiable, ObservableObject {
    let id = UUID()
    let request: AskpassRequest
    let receivedAt = Date()
    private var responder: ((AskpassReply) -> Void)?

    init(request: AskpassRequest, responder: @escaping (AskpassReply) -> Void) {
        self.request = request
        self.responder = responder
    }

    var tunnelID: UUID? { request.tunnelID.flatMap(UUID.init) }

    func answer(_ text: String) {
        responder?(AskpassReply(answer: text, cancelled: false))
        responder = nil
    }

    func cancel() {
        responder?(AskpassReply(answer: nil, cancelled: true))
        responder = nil
    }

    var isAnswered: Bool { responder == nil }
}

@MainActor
final class AskpassServer {
    let socketURL: URL
    var onPrompt: ((PendingPrompt) -> Void)?

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "io.binoio.Lincoln.askpass", qos: .userInitiated)

    /// Socket next to tunnels.json. Kept short: Unix socket paths max out at 104 bytes.
    nonisolated static func defaultSocketURL() -> URL {
        TunnelStore.defaultDirectory().appendingPathComponent("askpass.sock")
    }

    init(socketURL: URL? = nil) {
        self.socketURL = socketURL ?? AskpassServer.defaultSocketURL()
    }

    var isListening: Bool { listenFD >= 0 }

    /// The helper executable inside the app bundle, if present.
    static var helperURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/lincoln-askpass")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func start() throws {
        guard listenFD < 0 else { return }
        let path = socketURL.path
        guard path.utf8.count < 100 else { throw AskpassServerError.pathTooLong(path) }
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AskpassServerError.posix("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let error = errno
            close(fd)
            throw AskpassServerError.posix("bind", error)
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            let error = errno
            close(fd)
            unlink(path)
            throw AskpassServerError.posix("listen", error)
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection(listenFD: fd)
        }
        source.setCancelHandler {
            close(fd)
            unlink(path)
        }
        acceptSource = source
        source.resume()
        LogStore.log(level: .info, category: "Askpass", message: "Listening for ssh prompts", details: path)
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
    }

    nonisolated private func acceptConnection(listenFD: Int32) {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        // Read one JSON line.
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !data.contains(0x0A) && data.count < 65_536 {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        let line = data.prefix { $0 != 0x0A }
        guard let request = try? JSONDecoder().decode(AskpassRequest.self, from: line) else {
            close(client)
            return
        }
        let responder: (AskpassReply) -> Void = { reply in
            var payload = (try? JSONEncoder().encode(reply)) ?? Data("{\"cancelled\":true}".utf8)
            payload.append(0x0A)
            payload.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = write(client, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
            close(client)
        }
        Task { @MainActor in
            let pending = PendingPrompt(request: request, responder: responder)
            LogStore.log(level: .info, category: "Askpass", message: "ssh prompt received", details: request.prompt)
            if let onPrompt = self.onPrompt {
                onPrompt(pending)
            } else {
                pending.cancel()
            }
        }
    }
}

enum AskpassServerError: LocalizedError {
    case pathTooLong(String)
    case posix(String, Int32)

    var errorDescription: String? {
        switch self {
        case .pathTooLong(let path): return "Askpass socket path is too long: \(path)"
        case .posix(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
        }
    }
}

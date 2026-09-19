//
//  main.swift
//  lincoln-askpass
//
//  The program ssh runs (via SSH_ASKPASS) whenever it needs an answer from a
//  person. It forwards the prompt to the running Lincoln app over a local
//  socket and prints the answer Lincoln returns. Exit 1 tells ssh the
//  prompt was cancelled.
//

import Foundation
import Darwin

struct Request: Codable {
    var prompt: String
    var hint: String?
    var tunnelID: String?
}

struct Reply: Codable {
    var answer: String?
    var cancelled: Bool
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("lincoln-askpass: \(message)\n".utf8))
    exit(1)
}

let environment = ProcessInfo.processInfo.environment
guard let socketPath = environment["LINCOLN_ASKPASS_SOCKET"], !socketPath.isEmpty else {
    fail("LINCOLN_ASKPASS_SOCKET is not set")
}
let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
let request = Request(prompt: prompt, hint: environment["SSH_ASKPASS_PROMPT"], tunnelID: environment["LINCOLN_ASKPASS_TUNNEL"])

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fail("socket() failed") }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { fail("socket path too long") }
withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    for (index, byte) in pathBytes.enumerated() { buffer[index] = byte }
    buffer[pathBytes.count] = 0
}
let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0 else { fail("Lincoln is not listening at \(socketPath)") }

let encoder = JSONEncoder()
var payload = try! encoder.encode(request)
payload.append(0x0A)
payload.withUnsafeBytes { bytes in
    var offset = 0
    while offset < bytes.count {
        let written = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if written <= 0 { fail("write failed") }
        offset += written
    }
}

var received = Data()
var buffer = [UInt8](repeating: 0, count: 4096)
while !received.contains(0x0A) {
    let count = read(fd, &buffer, buffer.count)
    if count <= 0 { fail("Lincoln closed the connection without answering") }
    received.append(contentsOf: buffer[0..<count])
}
close(fd)

let line = received.prefix { $0 != 0x0A }
guard let reply = try? JSONDecoder().decode(Reply.self, from: line) else { fail("bad reply") }
if reply.cancelled {
    exit(1)
}
print(reply.answer ?? "")
exit(0)

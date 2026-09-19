//
//  SocketDirectoryWatcher.swift
//  Lincoln
//
//  Watches the directories that hold control sockets so Lincoln can notice a
//  master appearing (started by hand in a terminal) or disappearing without
//  polling while nothing is active.
//

import Foundation

@MainActor
final class SocketDirectoryWatcher {
    var onChange: (() -> Void)?

    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private let queue = DispatchQueue(label: "io.binoio.Lincoln.sockets")

    var watchedDirectories: Set<String> { Set(sources.keys) }

    /// Watches exactly these directories (existing ones only), dropping any
    /// that are no longer wanted.
    func watch(directories: Set<String>) {
        for (path, source) in sources where !directories.contains(path) {
            source.cancel()
            sources.removeValue(forKey: path)
        }
        for path in directories where sources[path] == nil {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.onChange?()
                }
            }
            source.setCancelHandler { close(fd) }
            sources[path] = source
            source.resume()
        }
    }

    func stop() {
        sources.values.forEach { $0.cancel() }
        sources.removeAll()
    }
}

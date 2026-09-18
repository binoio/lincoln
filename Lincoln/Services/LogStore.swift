//
//  LogStore.swift
//  Lincoln
//

import Foundation
import Combine

@MainActor
public final class LogStore: ObservableObject {
    public static let shared = LogStore()

    @Published public private(set) var entries: [LogEntry] = []
    @Published public var maxEntries: Int = 1000

    public init(maxEntries: Int = 1000) {
        self.maxEntries = maxEntries
        addEntry(LogEntry(level: .info, category: "System", message: "Lincoln log engine started."))
    }

    public func addEntry(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    public func log(
        level: LogLevel,
        category: String = "General",
        message: String,
        details: String? = nil
    ) {
        addEntry(LogEntry(level: level, category: category, message: message, details: details))
    }

    nonisolated public static func log(
        level: LogLevel,
        category: String = "General",
        message: String,
        details: String? = nil
    ) {
        let entry = LogEntry(level: level, category: category, message: message, details: details)
        NSLog("[%@] [%@] %@", level.rawValue.uppercased(), category, message + (details.map { "\n\($0)" } ?? ""))
        Task { @MainActor in
            shared.addEntry(entry)
        }
    }

    public func clear() {
        entries.removeAll()
        addEntry(LogEntry(level: .info, category: "System", message: "Logs cleared."))
    }

    public var exportFormattedText: String {
        entries.map { $0.fullFormattedString }.joined(separator: "\n\n" + String(repeating: "-", count: 60) + "\n\n")
    }
}

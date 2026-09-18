//
//  LogEntry.swift
//  Lincoln
//

import Foundation

public enum LogLevel: String, Codable, CaseIterable, Identifiable {
    case info = "INFO"
    case success = "SUCCESS"
    case warning = "WARNING"
    case error = "ERROR"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

public struct LogEntry: Identifiable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String
    public let details: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        category: String = "General",
        message: String,
        details: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.details = details
    }

    public var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }

    public var fullFormattedString: String {
        let dateStr = DateFormatter.localizedString(from: timestamp, dateStyle: .short, timeStyle: .medium)
        var result = "[\(dateStr)] [\(level.rawValue)] [\(category)] \(message)"
        if let details = details, !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += "\nDetails:\n\(details)"
        }
        return result
    }
}

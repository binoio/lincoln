//
//  TunnelStore.swift
//  LincolnCore
//
//  JSON persistence for TunnelDocument. Writes are atomic, loads tolerate a
//  missing file, migrate older schema versions and quarantine (never delete)
//  a corrupt file so the user can recover it by hand.
//

import Foundation

public enum TunnelStoreError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
}

public struct TunnelStoreLoadResult: Equatable {
    public var document: TunnelDocument
    /// Set when the file existed but could not be decoded; the original was
    /// moved aside to this URL.
    public var quarantinedFileURL: URL?
    /// Set when an older schema was migrated (the caller should save).
    public var migratedFromSchemaVersion: Int?

    public init(document: TunnelDocument, quarantinedFileURL: URL? = nil, migratedFromSchemaVersion: Int? = nil) {
        self.document = document
        self.quarantinedFileURL = quarantinedFileURL
        self.migratedFromSchemaVersion = migratedFromSchemaVersion
    }
}

public final class TunnelStore {
    public let fileURL: URL
    private let fileManager: FileManager

    /// ~/Library/Application Support/Lincoln/tunnels.json — outside the app
    /// bundle, so trashing Lincoln.app leaves it intact.
    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Lincoln", isDirectory: true)
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        defaultDirectory(fileManager: fileManager).appendingPathComponent("tunnels.json")
    }

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public var directoryURL: URL { fileURL.deletingLastPathComponent() }

    public func load() throws -> TunnelStoreLoadResult {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return TunnelStoreLoadResult(document: .empty)
        }
        let data = try Data(contentsOf: fileURL)
        do {
            let (document, migratedFrom) = try TunnelStore.decode(data)
            return TunnelStoreLoadResult(document: document, migratedFromSchemaVersion: migratedFrom)
        } catch {
            let quarantine = quarantineURL()
            try? fileManager.moveItem(at: fileURL, to: quarantine)
            return TunnelStoreLoadResult(document: .empty, quarantinedFileURL: quarantine)
        }
    }

    public func save(_ document: TunnelDocument) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var normalized = document
        normalized.schemaVersion = TunnelDocument.currentSchemaVersion
        let data = try TunnelStore.encode(normalized)
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Codec

    public static func encode(_ document: TunnelDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    /// Decodes any supported schema version, migrating forward as needed.
    public static func decode(_ data: Data) throws -> (TunnelDocument, migratedFrom: Int?) {
        let probe = try JSONDecoder().decode(SchemaProbe.self, from: data)
        let version = probe.schemaVersion ?? 1
        switch version {
        case TunnelDocument.currentSchemaVersion:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try decoder.decode(TunnelDocument.self, from: data), nil)
        default:
            // Future schema versions land here with a migration step each.
            throw TunnelStoreError.unsupportedSchemaVersion(version)
        }
    }

    private struct SchemaProbe: Decodable {
        var schemaVersion: Int?
    }

    private func quarantineURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        return directoryURL.appendingPathComponent("tunnels.json.corrupt-\(stamp)")
    }
}

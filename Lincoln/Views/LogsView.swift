//
//  LogsView.swift
//  Lincoln
//

import SwiftUI
import AppKit

public enum LogLevelFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case info = "INFO"
    case success = "SUCCESS"
    case warning = "WARNING"
    case error = "ERROR"

    public var id: String { rawValue }
}

public struct LogsView: View {
    @ObservedObject var logStore: LogStore

    @State private var searchText: String = ""
    @State private var selectedLevelFilter: LogLevelFilter = .all
    @State private var autoScroll: Bool = true
    @State private var expandedEntryIds: Set<UUID> = []
    @State private var showCopiedBanner: Bool = false

    @MainActor
    public init(logStore: LogStore = LogStore.shared) {
        self.logStore = logStore
    }

    public var filteredEntries: [LogEntry] {
        logStore.entries.filter { entry in
            let matchesLevel: Bool
            switch selectedLevelFilter {
            case .all: matchesLevel = true
            case .info: matchesLevel = entry.level == .info
            case .success: matchesLevel = entry.level == .success
            case .warning: matchesLevel = entry.level == .warning
            case .error: matchesLevel = entry.level == .error
            }

            let matchesSearch = searchText.isEmpty ||
                entry.message.localizedCaseInsensitiveContains(searchText) ||
                entry.category.localizedCaseInsensitiveContains(searchText) ||
                (entry.details?.localizedCaseInsensitiveContains(searchText) ?? false)

            return matchesLevel && matchesSearch
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // MARK: - Filter Bar
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search logs...", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

                Picker("Filter", selection: $selectedLevelFilter) {
                    ForEach(LogLevelFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .font(.subheadline)
            }
            .padding(10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // MARK: - Copy Banner
            if showCopiedBanner {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Logs copied to clipboard")
                        .font(.caption.bold())
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(Color.green.opacity(0.15))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // MARK: - Log List View
            if filteredEntries.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No diagnostic log entries match filter")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(filteredEntries) { entry in
                            LogEntryRow(
                                entry: entry,
                                isExpanded: expandedEntryIds.contains(entry.id),
                                onToggleExpand: {
                                    if expandedEntryIds.contains(entry.id) {
                                        expandedEntryIds.remove(entry.id)
                                    } else {
                                        expandedEntryIds.insert(entry.id)
                                    }
                                }
                            )
                            .id(entry.id)
                        }
                    }
                    .listStyle(.inset)
                    .onChange(of: logStore.entries.count) {
                        if autoScroll, let last = filteredEntries.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            Divider()

            // MARK: - Footer & Diagnostics Summary
            HStack {
                let errorCount = logStore.entries.filter { $0.level == .error }.count
                let warningCount = logStore.entries.filter { $0.level == .warning }.count
                
                HStack(spacing: 12) {
                    Text("\(logStore.entries.count) total entries")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if warningCount > 0 {
                        Label("\(warningCount) warnings", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    if errorCount > 0 {
                        Label("\(errorCount) errors", systemImage: "xmark.octagon.fill")
                            .font(.caption.bold())
                            .foregroundColor(.red)
                    } else {
                        Label("0 errors", systemImage: "checkmark.shield.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }

                Spacer()

                Button {
                    copyToClipboard()
                } label: {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Button {
                    exportLogs()
                } label: {
                    Label("Export...", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Button {
                    logStore.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundColor(.red)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .navigationTitle("Diagnostic Logs")
        .frame(minWidth: 550, idealWidth: 650, maxWidth: 900, minHeight: 350, idealHeight: 450, maxHeight: 800)
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logStore.exportFormattedText, forType: .string)
        withAnimation {
            showCopiedBanner = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showCopiedBanner = false
            }
        }
    }

    private func exportLogs() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "lincoln-diagnostics-\(Int(Date().timeIntervalSince1970)).log"
        savePanel.title = "Export Diagnostic Logs"
        savePanel.prompt = "Export"

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                do {
                    try logStore.exportFormattedText.write(to: url, atomically: true, encoding: .utf8)
                    LogStore.log(level: .info, category: "Export", message: "Logs exported successfully to \(url.lastPathComponent)")
                } catch {
                    LogStore.log(level: .error, category: "Export", message: "Failed to export logs", details: error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Row View Component

struct LogEntryRow: View {
    let entry: LogEntry
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    var levelColor: Color {
        switch entry.level {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: entry.level.iconName)
                    .foregroundColor(levelColor)
                    .font(.body)

                Text(entry.formattedTimestamp)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)

                Text(entry.category.uppercased())
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(levelColor.opacity(0.12))
                    .foregroundColor(levelColor)
                    .cornerRadius(4)

                Text(entry.message)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(isExpanded ? nil : 1)

                Spacer()

                if entry.details != nil && !entry.details!.isEmpty {
                    Button(action: onToggleExpand) {
                        HStack(spacing: 4) {
                            Text(isExpanded ? "Hide Details" : "Details")
                                .font(.caption)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            if isExpanded, let details = entry.details, !details.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("DIAGNOSTIC OUTPUT & CLI TRACE")
                            .font(.caption2.bold())
                            .foregroundColor(.secondary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.fullFormattedString, forType: .string)
                        } label: {
                            Label("Copy Entry", systemImage: "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }

                    Text(details)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(Color(NSColor.textColor))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                }
                .padding(.top, 4)
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 4)
    }
}

//
//  ConsoleBuffer.swift
//  LincolnCore
//
//  Bounded scrollback for one tunnel's console. Keeps whole lines plus the
//  unterminated tail so prompts (which end without a newline) can be
//  detected.
//

import Foundation

public struct ConsoleBuffer: Equatable {
    public private(set) var lines: [String] = []
    public private(set) var tail: String = ""
    public var maximumLines: Int

    public init(maximumLines: Int = 5_000) {
        self.maximumLines = maximumLines
    }

    /// Appends already-stripped text.
    public mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        var pieces = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let endsWithNewline = text.hasSuffix("\n")
        if endsWithNewline { pieces.removeLast() }
        guard !pieces.isEmpty else { return }

        pieces[0] = tail + pieces[0]
        tail = ""
        if endsWithNewline {
            lines.append(contentsOf: pieces)
        } else {
            tail = pieces.removeLast()
            lines.append(contentsOf: pieces)
        }
        if lines.count > maximumLines {
            lines.removeFirst(lines.count - maximumLines)
        }
    }

    /// Records a line Lincoln itself adds (timestamps, state changes).
    public mutating func appendSystemLine(_ line: String) {
        flushTail()
        lines.append(line)
        if lines.count > maximumLines {
            lines.removeFirst(lines.count - maximumLines)
        }
    }

    /// Moves the pending tail into a full line (after the user answered a prompt).
    public mutating func flushTail() {
        guard !tail.isEmpty else { return }
        lines.append(tail)
        tail = ""
    }

    public mutating func clear() {
        lines.removeAll()
        tail = ""
    }

    public var text: String {
        var result = lines.joined(separator: "\n")
        if !tail.isEmpty {
            if !result.isEmpty { result += "\n" }
            result += tail
        }
        return result
    }

    /// The last few lines plus tail, for failure reasons.
    public func recentText(lineCount: Int = 20) -> String {
        let slice = lines.suffix(lineCount)
        var result = slice.joined(separator: "\n")
        if !tail.isEmpty {
            if !result.isEmpty { result += "\n" }
            result += tail
        }
        return result
    }
}

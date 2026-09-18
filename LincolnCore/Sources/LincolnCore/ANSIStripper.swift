//
//  ANSIStripper.swift
//  LincolnCore
//
//  Lincoln's console is a plain scrollback, not a terminal emulator, so
//  escape sequences and carriage-return tricks are removed before display.
//

import Foundation

public enum ANSIStripper {
    public static func strip(_ input: String) -> String {
        var output = ""
        output.reserveCapacity(input.count)
        var iterator = input.makeIterator()
        while let character = iterator.next() {
            switch character {
            case "\u{1B}":
                consumeEscape(&iterator)
            case "\u{07}":
                continue
            case "\r\n":
                // Swift treats CRLF as a single grapheme cluster.
                output.append("\n")
            case "\r":
                continue
            default:
                output.append(character)
            }
        }
        return output
    }

    private static func consumeEscape(_ iterator: inout String.Iterator) {
        guard let next = iterator.next() else { return }
        switch next {
        case "[":
            // CSI: parameters 0x30–0x3F, intermediates 0x20–0x2F, final 0x40–0x7E.
            while let c = iterator.next() {
                if let scalar = c.unicodeScalars.first, scalar.value >= 0x40, scalar.value <= 0x7E { return }
            }
        case "]":
            // OSC: terminated by BEL or ESC \.
            var previousWasEscape = false
            while let c = iterator.next() {
                if c == "\u{07}" { return }
                if previousWasEscape && c == "\\" { return }
                previousWasEscape = (c == "\u{1B}")
            }
        case "(", ")", "#", "%":
            _ = iterator.next()
        default:
            return
        }
    }
}

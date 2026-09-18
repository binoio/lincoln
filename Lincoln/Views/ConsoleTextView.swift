//
//  ConsoleTextView.swift
//  Lincoln
//
//  Read-only monospaced scrollback backed by NSTextView (SwiftUI Text is
//  too slow for thousands of lines). Auto-scrolls when pinned to the bottom.
//

import SwiftUI
import AppKit

struct ConsoleTextView: NSViewRepresentable {
    var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor.textColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.string = text
        context.coordinator.scrollToBottom(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        guard textView.string != text else { return }
        let wasAtBottom = context.coordinator.isAtBottom(scrollView)
        textView.string = text
        if wasAtBottom {
            context.coordinator.scrollToBottom(textView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        func isAtBottom(_ scrollView: NSScrollView) -> Bool {
            guard let documentView = scrollView.documentView else { return true }
            let visible = scrollView.contentView.bounds
            return documentView.bounds.maxY - visible.maxY < 24
        }

        func scrollToBottom(_ textView: NSTextView) {
            textView.scrollToEndOfDocument(nil)
        }
    }
}

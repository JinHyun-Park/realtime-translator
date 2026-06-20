import AppKit
import SwiftUI

/// A read-only but fully selectable, scrollable text view backed by NSTextView.
///
/// Why not a SwiftUI `Text` stack: in SwiftUI each `Text` is its own selection
/// "island", so a `VStack` of lines can only be drag-selected one line at a
/// time. A single NSTextView is ONE selection surface — the user can drag across
/// the entire transcript at once, Cmd+A to select all, and Cmd+C to copy.
///
/// Live-update friendliness (the transcript grows while the user may be
/// selecting): we preserve the current selection across content swaps, and only
/// auto-scroll to the bottom when the user was already pinned there AND isn't
/// mid-selection — so a refresh never yanks the view away while they read or
/// select older text.
struct SelectableText: NSViewRepresentable {
    let attributed: NSAttributedString
    /// Stick to the bottom as content grows (transcript). Off for static blocks.
    var autoScroll: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 2, height: 4)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.allowsUndo = false

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView,
              let storage = tv.textStorage else { return }
        // Nothing changed? Leave it alone (avoids clobbering an in-progress drag).
        if storage.isEqual(to: attributed) { return }

        let wasAtBottom = context.coordinator.isAtBottom(scroll)
        let sel = tv.selectedRange()
        let hadSelection = sel.length > 0

        storage.setAttributedString(attributed)

        // Restore the prior selection if it still fits (transcript mostly grows
        // by appending, so earlier ranges stay valid).
        if hadSelection {
            let maxLen = storage.length
            if sel.location <= maxLen {
                tv.setSelectedRange(NSRange(location: sel.location,
                                            length: min(sel.length, maxLen - sel.location)))
            }
        }

        if autoScroll && wasAtBottom && !hadSelection {
            tv.scrollToEndOfDocument(nil)
        }
    }

    final class Coordinator {
        weak var textView: NSTextView?
        /// True if the scroll view is within a small threshold of the bottom.
        func isAtBottom(_ scroll: NSScrollView) -> Bool {
            guard let doc = scroll.documentView else { return true }
            let visible = scroll.contentView.bounds
            let maxY = doc.bounds.height
            // 40pt slack so "basically at the bottom" still counts.
            return visible.maxY >= maxY - 40
        }
    }
}

import AppKit
import SwiftUI

/// Live subtitle / transcript. Finalized lines are solid; the in-progress
/// interim line is shown greyed at the bottom and keeps getting revised.
///
/// Rendered as ONE NSTextView (via SelectableText) so the whole transcript is a
/// single selection surface — the user can drag across every line at once,
/// Cmd+A, and copy. (A SwiftUI `Text` stack only selects one line at a time.)
struct TranscriptView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSource = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Translation").font(.headline)
                Spacer()
                Toggle("Show original", isOn: $showSource)
                    .toggleStyle(.switch).controlSize(.mini)
                // Auto-saved to disk live; this just reveals the folder.
                Button { model.revealAutosaveFolder() } label: {
                    Label("저장폴더", systemImage: "folder")
                }
                .controlSize(.small)
                .help("자막은 자동 저장됩니다. 폴더 열기")
                Button { model.exportMarkdown() } label: {
                    Label("Export .md", systemImage: "square.and.arrow.down")
                }
                .controlSize(.small)
                .disabled(model.lines.isEmpty)
                Button(role: .destructive) { model.clearTranscript() } label: {
                    Label("Clear", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(model.lines.isEmpty)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()

            SelectableText(attributed: transcriptAttributed(), autoScroll: true)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            // Rolling ticker: the in-progress line lives HERE, in a fixed
            // one-line-per-stream strip below the transcript — the newest text
            // replaces the previous in place, so confirmed lines above never
            // reflow or jump while someone is speaking.
            if model.micInterim != nil || model.sysInterim != nil {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("ticker.label"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color.secondary.opacity(0.7))
                    if let s = model.sysInterim { tickerRow(s) }
                    if let m = model.micInterim { tickerRow(m) }
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
            }
        }
    }

    /// One fixed ticker row: tag + tail-truncated in-progress translation.
    private func tickerRow(_ line: Line) -> some View {
        HStack(spacing: 6) {
            Text(line.stream == "mic" ? "ME" : "THEM")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(line.stream == "mic" ? Color.blue : Color.green)
                .foregroundColor(.white)
                .cornerRadius(4)
            Text(line.translation.isEmpty ? line.source : line.translation)
                .font(.system(size: 13))
                .italic()
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.head)   // keep the TAIL (newest words) visible
            Spacer(minLength: 0)
        }
    }

    /// Build the whole transcript (confirmed lines only — the in-progress
    /// preview lives in the fixed ticker strip below, not in this flow).
    private func transcriptAttributed() -> NSAttributedString {
        let out = NSMutableAttributedString()
        for line in model.lines {
            out.append(TranscriptStyle.block(line, showSource: showSource, dim: false))
        }
        if out.length == 0 {
            return NSAttributedString(
                string: "대화가 시작되면 여기에 번역이 표시됩니다.",
                attributes: [.foregroundColor: NSColor.tertiaryLabelColor,
                             .font: NSFont.systemFont(ofSize: 13)])
        }
        return out
    }
}

/// Attributed-string styling for one transcript line, mirroring the old
/// SwiftUI row (ME/THEM color, source greyed, translation bold).
enum TranscriptStyle {
    static func block(_ line: Line, showSource: Bool, dim: Bool) -> NSAttributedString {
        let isMic = line.stream == "mic"
        let s = NSMutableAttributedString()
        let labelColor = isMic ? NSColor.systemBlue : NSColor.systemGreen
        let who = isMic ? "ME" : "THEM"

        // Speaker + (optional) source line.
        s.append(tag("\(who) ", color: labelColor))
        if showSource {
            s.append(tag("\(line.src.uppercased()) ", color: .secondaryLabelColor))
            s.append(NSAttributedString(string: line.source, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        s.append(NSAttributedString(string: "\n"))

        // Translation line (bold, larger).
        let transColor: NSColor = dim ? .secondaryLabelColor : .labelColor
        s.append(tag("\(line.tgt.uppercased()) ", color: .secondaryLabelColor))
        s.append(NSAttributedString(
            string: (line.translation.isEmpty ? "…" : line.translation) + "\n\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 16,
                                         weight: dim ? .regular : .semibold),
                .foregroundColor: transColor,
            ]))
        return s
    }

    private static func tag(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: color,
        ])
    }
}

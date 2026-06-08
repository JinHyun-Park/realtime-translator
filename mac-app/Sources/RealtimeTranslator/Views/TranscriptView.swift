import SwiftUI

/// Live subtitle / transcript. Finalized lines are solid; the in-progress
/// interim line is shown greyed at the bottom and keeps getting revised.
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

            ScrollViewReader { proxy in
                ScrollView {
                    // textSelection lets the user drag-select & copy lines, but
                    // Text views are inherently read-only (no typing into them).
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.lines) { line in
                            LineRow(line: line, showSource: showSource, dim: false)
                                .id(line.id)
                        }
                        if let it = model.interim {
                            LineRow(line: it, showSource: showSource, dim: true)
                                .id(-1)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.lines.count) { _, _ in
                    withAnimation { proxy.scrollTo(model.lines.last?.id ?? -1, anchor: .bottom) }
                }
                .onChange(of: model.interim?.translation) { _, _ in
                    withAnimation { proxy.scrollTo(-1, anchor: .bottom) }
                }
            }
        }
    }
}

private struct LineRow: View {
    let line: Line
    let showSource: Bool
    let dim: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showSource {
                HStack(spacing: 6) {
                    Tag(text: line.src.uppercased())
                    Text(line.source)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 6) {
                Tag(text: line.tgt.uppercased())
                Text(line.translation.isEmpty ? "…" : line.translation)
                    .font(.title3)
                    .fontWeight(dim ? .regular : .semibold)
            }
        }
        .opacity(dim ? 0.55 : 1.0)
        .padding(.vertical, 4)
    }
}

private struct Tag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2).monospaced()
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
    }
}

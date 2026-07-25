import SwiftUI
import CygnusKit

// The inspector's code pane: the selected node's source, line
// numbers, anchor line highlighted and scrolled into view. A preview,
// not an editor — read-only, size-capped upstream.

struct CodePreviewView: View {
    let preview: SourcePreview
    /// 1-based line to highlight (the node's source anchor).
    let highlightLine: Int?

    private var language: String? {
        switch (preview.path as NSString).pathExtension.lowercased() {
        case "swift": "swift"
        case "py": "python"
        case "c", "h": "c"
        default: nil
        }
    }

    var body: some View {
        // GeometryReader pins the content's minimum width to the
        // pane, so rows (and the highlight band) stretch with it while
        // long lines still scroll horizontally.
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(preview.lines.enumerated()), id: \.offset) { index, line in
                            let number = index + 1
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(number)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 40, alignment: .trailing)
                                Text(SyntaxHighlighter.highlight(line, language: language))
                                    .font(.system(size: 11, design: .monospaced))
                                    .opacity(number == highlightLine ? 1 : 0.85)
                            }
                            .padding(.vertical, 0.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(number == highlightLine
                                        ? Color.accentColor.opacity(0.18) : .clear)
                            .id(number)
                        }
                        if preview.truncated {
                            Text("— truncated —")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(6)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
                    .frame(minWidth: geometry.size.width, alignment: .topLeading)
                }
                .onAppear {
                    if let line = highlightLine {
                        proxy.scrollTo(line, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

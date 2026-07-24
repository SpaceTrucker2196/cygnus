import SwiftUI
import CygnusKit

// Block-by-block markdown rendering on built-in AttributedString (no
// external dependency). Checklist items are interactive when `onToggle`
// is provided (Docs editor) and static otherwise (issue bodies).

struct MarkdownRenderView: View {
    let document: MarkdownDocument
    var onToggle: ((ChecklistItem) -> Void)?

    init(source: String, onToggle: ((ChecklistItem) -> Void)? = nil) {
        self.document = MarkdownDocument(source: source)
        self.onToggle = onToggle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text).font(headingFont(level)).fontWeight(.semibold)
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            inlineText(text)
        case .listItem(let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inlineText(text)
            }
            .padding(.leading, CGFloat(indent) * 8)
        case .checklist(let item):
            ChecklistRow(item: item, onToggle: onToggle)
        case .codeBlock(_, let lines):
            Text(lines.joined(separator: "\n"))
                .font(.callout.monospaced())
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .blockquote(let text):
            HStack(spacing: 8) {
                Rectangle().fill(.secondary).frame(width: 3)
                inlineText(text).foregroundStyle(.secondary)
            }
        case .rule:
            Divider()
        case .blank:
            EmptyView()
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title
        case 2: .title2
        case 3: .title3
        default: .headline
        }
    }

    /// Render inline spans (bold/italic/code/links) via AttributedString.
    private func inlineText(_ raw: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(raw)
    }
}

private struct ChecklistRow: View {
    let item: ChecklistItem
    var onToggle: ((ChecklistItem) -> Void)?

    var body: some View {
        Button {
            onToggle?(item)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                Text(item.text)
                    .strikethrough(item.mark == .done, color: .secondary)
                    .foregroundStyle(item.mark == .done ? .secondary : .primary)
            }
        }
        .buttonStyle(.plain)
        .disabled(onToggle == nil)
    }

    private var symbol: String {
        switch item.mark {
        case .todo: "square"
        case .wip: "square.lefthalf.filled"
        case .done: "checkmark.square.fill"
        }
    }
    private var color: Color {
        switch item.mark {
        case .todo: .secondary
        case .wip: .orange
        case .done: .green
        }
    }
}

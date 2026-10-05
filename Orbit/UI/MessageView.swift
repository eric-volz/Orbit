import SwiftUI

/// The user's message: a subtle bubble on the trailing side, followed by the
/// context chips that were sent with it.
struct UserMessageView: View, Equatable {
    let text: String
    let attachments: [ContextAttachment]

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(verbatim: text)
                .font(Theme.bodyFont)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius, style: .continuous)
                        .fill(Theme.userBubbleFill)
                )
                .contrastEdge(RoundedRectangle(cornerRadius: Theme.bubbleCornerRadius, style: .continuous),
                              color: .accentColor)
            if !attachments.isEmpty {
                FlowLayout(alignment: .trailing) {
                    ForEach(attachments) { attachment in
                        ContextChip(attachment: attachment)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 64)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: String(format: String(localized: "You: %@"), text)))
    }
}

/// A Markdown answer. While it streams, a soft typing indicator follows the text.
///
/// While streaming, the finished paragraphs render as one view that does not
/// change with further deltas, and only the growing last part is re-parsed, so
/// long answers stay fast. The complete answer renders as a whole, in the
/// same view that showed the finished paragraphs (`AnswerParts`): only the
/// blocks that changed are built again when the answer ends, instead of the
/// whole answer at once (measured: 350 ms for 33,000 characters).
struct AssistantMessageView: View, Equatable {
    let text: String
    let isStreaming: Bool

    var body: some View {
        let parts = AnswerParts(text: text, isStreaming: isStreaming)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                if !parts.main.isEmpty {
                    MarkdownView(text: parts.main)
                        .equatable()
                }
                if !parts.tail.isEmpty {
                    MarkdownView(text: parts.tail)
                        .equatable()
                }
            }
            if isStreaming {
                TypingIndicator()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// How an answer is split into the two Markdown views of `AssistantMessageView`.
/// While it streams: the part that no longer changes (up to the last blank
/// line outside a code fence) and the growing rest with its open inline
/// markers closed; as long as nothing is stable yet, the rest goes first.
/// Complete: the whole text in the first view, so SwiftUI keeps the view that
/// showed the answer's beginning and rebuilds only the blocks that changed.
struct AnswerParts: Equatable, Sendable {
    var main: String
    var tail: String

    init(text: String, isStreaming: Bool) {
        guard isStreaming else {
            main = text
            tail = ""
            return
        }
        let split = MarkdownStreaming.stableSplit(text)
        let rest = split.tail.isEmpty ? "" : MarkdownStreaming.closingOpenInlineMarkers(split.tail)
        (main, tail) = split.stable.isEmpty ? (rest, "") : (split.stable, rest)
    }
}

/// Three softly pulsing dots ("Orbit is answering…"). Static with Reduce Motion.
struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                dots(highlighted: nil)
            } else {
                PhaseAnimator([0, 1, 2]) { phase in
                    dots(highlighted: phase)
                } animation: { _ in
                    .easeInOut(duration: 0.42)
                }
            }
        }
        .frame(height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Orbit is answering…"))
    }

    private func dots(highlighted: Int?) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 6, height: 6)
                    .opacity(highlighted.map { $0 == index ? 0.85 : 0.3 } ?? 0.6)
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// Lays out subviews left to right and wraps them into further lines.
struct FlowLayout: Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let lines = FlowLayout.lines(for: sizes, maxWidth: proposal.width ?? .infinity, spacing: spacing)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let lines = FlowLayout.lines(for: sizes, maxWidth: bounds.width, spacing: spacing)
        var y = bounds.minY
        for line in lines {
            var x: CGFloat
            switch alignment {
            case .trailing: x = bounds.maxX - line.width
            case .center: x = bounds.minX + (bounds.width - line.width) / 2
            default: x = bounds.minX
            }
            for index in line.indices {
                let size = sizes[index]
                let width = min(size.width, bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                                      proposal: ProposedViewSize(width: width, height: size.height))
                x += width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    struct Line: Equatable {
        var indices: [Int]
        var width: CGFloat
        var height: CGFloat
    }

    /// Greedy line breaking. A subview wider than `maxWidth` gets a line of
    /// its own (and is clamped to the width when placed).
    static func lines(for sizes: [CGSize], maxWidth: CGFloat, spacing: CGFloat) -> [Line] {
        var lines: [Line] = []
        var current = Line(indices: [], width: 0, height: 0)
        for (index, size) in sizes.enumerated() {
            let width = min(size.width, maxWidth)
            let proposedWidth = current.indices.isEmpty ? width : current.width + spacing + width
            if !current.indices.isEmpty, proposedWidth > maxWidth {
                lines.append(current)
                current = Line(indices: [index], width: width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = proposedWidth
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }
}

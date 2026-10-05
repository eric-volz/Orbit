import SwiftUI

/// The context captured when the panel opened ("With selection: Angebot.pdf"),
/// shown above the input. Each chip can be removed before sending: with its
/// ×, with VoiceOver's "Remove", or (like a token field) with ⌫ in the
/// empty input, which removes the last one (`ContextChipRemoval`).
struct ContextChips: View {
    let attachments: [ContextAttachment]
    let onRemove: (ContextAttachment) -> Void

    var body: some View {
        FlowLayout {
            ForEach(attachments) { attachment in
                ContextChip(attachment: attachment) {
                    onRemove(attachment)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Context"))
    }
}

/// One context chip. Without `onRemove` it is read-only (sent messages).
struct ContextChip: View {
    let attachment: ContextAttachment
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: Self.systemImage(for: attachment.kind))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(verbatim: attachment.label)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel(Text(verbatim: String(format: String(localized: "Context: %@"), attachment.label)))
                .accessibilityActions {
                    if let onRemove {
                        Button(String(localized: "Remove"), action: onRemove)
                    }
                }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(Text("Remove Context"))
                .accessibilityLabel(Text(verbatim: String(format: String(localized: "Remove %@"), attachment.label)))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, onRemove == nil ? 8 : 4)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(Theme.chipFill))
        .contrastEdge(Capsule())
        .frame(maxWidth: 360, alignment: .leading)
    }

    static func systemImage(for kind: ContextAttachment.Kind) -> String {
        switch kind {
        case .finderSelection: "doc"
        case .selectedText: "text.quote"
        case .frontmostApp: "macwindow"
        }
    }
}

/// Removing context chips from the keyboard, like tokens in a token field:
/// ⌫ in the empty input removes the last chip. VoiceOver hears which one, because
/// the keyboard stays in the input, so it would not notice.
enum ContextChipRemoval {
    /// The chip ⌫ removes: the last one, and only while the input is empty
    /// (otherwise ⌫ edits the text).
    static func chipToRemove(inputText: String, attachments: [ContextAttachment]) -> ContextAttachment? {
        guard inputText.isEmpty else { return nil }
        return attachments.last
    }

    /// "Context removed: With selection: Angebot.pdf".
    static func announcement(for attachment: ContextAttachment) -> String {
        String(format: String(localized: "Context removed: %@"), attachment.label)
    }
}

import AppKit
import SwiftUI

/// Layout metrics, fonts and colors shared by the panel, the chat and the
/// settings. Colors are semantic and adapt to light and dark mode.
enum Theme {
    // MARK: Panel

    /// Maximum width of the panel content.
    static let panelWidth: CGFloat = 720
    /// Horizontal inset of the input bar and the chat.
    static let contentInset: CGFloat = 18
    static let inputFontSize: CGFloat = 22
    static let inputIconSize: CGFloat = 20

    // MARK: Text

    /// Chat text size (slightly larger than the macOS body size, like Spotlight).
    static let bodySize: CGFloat = 14
    static let bodyFont = Font.system(size: bodySize)
    static let secondaryFont = Font.system(size: 12)
    static let footnoteFont = Font.system(size: 11)
    static let codeFont = Font.system(size: 12.5, design: .monospaced)

    // MARK: Shapes

    static let rowCornerRadius: CGFloat = 8
    static let cardCornerRadius: CGFloat = 10
    static let bubbleCornerRadius: CGFloat = 14

    // MARK: Colors

    static let cardFill = Color.primary.opacity(0.045)
    static let hoverFill = Color.primary.opacity(0.06)
    static let selectionFill = Color.accentColor.opacity(0.22)
    /// A selection in a list that does not have the keyboard.
    static let inactiveSelectionFill = Color.primary.opacity(0.1)
    static let codeFill = Color.primary.opacity(0.06)
    static let userBubbleFill = Color.accentColor.opacity(0.13)
    static let chipFill = Color.primary.opacity(0.07)

    // MARK: Accessibility display options

    /// Increase Contrast: the edge of a card, chip, bubble, notice or key cap is drawn clearly;
    /// shapes that are otherwise a faint fill get one too.
    static let increasedContrastEdgeOpacity = 0.5

    /// The opacity of a card's border.
    static func cardStrokeOpacity(increasedContrast: Bool) -> Double {
        increasedContrast ? increasedContrastEdgeOpacity : 0.09
    }

    /// Whether a selected row is outlined: with Increase Contrast, and with Differentiate
    /// Without Color while its list has the keyboard (otherwise only the accent color tells
    /// that it has the keyboard).
    static func outlinesSelection(isFocused: Bool, increasedContrast: Bool, differentiateWithoutColor: Bool) -> Bool {
        increasedContrast || (differentiateWithoutColor && isFocused)
    }

    /// The color for a tool risk level (badges, confirmation cards).
    static func color(for riskLevel: ToolRiskLevel) -> Color {
        switch riskLevel {
        case .read: .secondary
        case .draft: .blue
        case .write: .orange
        case .destructive: .red
        }
    }

    /// Parses "#RRGGBB" (or "RRGGBB") into components in 0…1.
    static func rgbComponents(fromHex hex: String) -> (red: Double, green: Double, blue: Double)? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return (
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// A color from "#RRGGBB", or nil when the text is not a hex color.
    static func color(hex: String?) -> Color? {
        guard let hex, let components = rgbComponents(fromHex: hex) else { return nil }
        return Color(red: components.red, green: components.green, blue: components.blue)
    }
}

// MARK: - Reusable modifiers

/// The rounded, subtly filled container used by result and confirmation cards
/// (a clear border with Increase Contrast).
struct CardBackground: ViewModifier {
    var tint: Color?
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
        let increased = contrast == .increased
        content
            .background(shape.fill(tint.map { $0.opacity(0.07) } ?? Theme.cardFill))
            .overlay(shape.strokeBorder(tint.map { $0.opacity(increased ? 0.8 : 0.35) }
                                        ?? Color.primary.opacity(Theme.cardStrokeOpacity(increasedContrast: increased)),
                                        lineWidth: 1))
    }
}

/// Increase Contrast: a clear edge around a shape that is otherwise only a faint
/// fill (chips, bubbles, notices, key caps, code).
struct ContrastEdge<S: InsettableShape>: ViewModifier {
    let shape: S
    var color: Color = .primary
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.overlay {
            if contrast == .increased {
                shape.strokeBorder(color.opacity(Theme.increasedContrastEdgeOpacity), lineWidth: 1)
            }
        }
    }
}

/// Highlights a row on hover (subtle) and when selected (accent; gray when
/// its list does not have the keyboard), outlined as `Theme.outlinesSelection` says.
struct RowHighlight: ViewModifier {
    var isSelected = false
    var isFocused = true
    var cornerRadius: CGFloat = Theme.rowCornerRadius
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RowSelectionBackground(isSelected: isSelected, isFocused: isFocused, cornerRadius: cornerRadius,
                                       unselectedFill: isHovered ? Theme.hoverFill : .clear)
            )
            .onHover { isHovered = $0 }
    }
}

/// The selection of a row that does not react to the pointer: accent while its
/// list has the keyboard, gray otherwise; outlined with Increase Contrast, and
/// with Differentiate Without Color while it has the keyboard.
struct RowSelectionBackground: View {
    var isSelected: Bool
    var isFocused: Bool
    var cornerRadius: CGFloat = Theme.rowCornerRadius
    /// The fill of an unselected row (hover).
    var unselectedFill: Color = .clear
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(isSelected ? (isFocused ? Theme.selectionFill : Theme.inactiveSelectionFill) : unselectedFill)
            .overlay {
                if isSelected, Theme.outlinesSelection(isFocused: isFocused, increasedContrast: contrast == .increased,
                                                       differentiateWithoutColor: differentiateWithoutColor) {
                    shape.strokeBorder(isFocused ? Color.accentColor : Color.secondary, lineWidth: 1.5)
                }
            }
    }
}

extension View {
    func cardBackground(tint: Color? = nil) -> some View {
        modifier(CardBackground(tint: tint))
    }

    func rowHighlight(isSelected: Bool = false, isFocused: Bool = true,
                      cornerRadius: CGFloat = Theme.rowCornerRadius) -> some View {
        modifier(RowHighlight(isSelected: isSelected, isFocused: isFocused, cornerRadius: cornerRadius))
    }

    /// See `ContrastEdge`.
    func contrastEdge<S: InsettableShape>(_ shape: S, color: Color = .primary) -> some View {
        modifier(ContrastEdge(shape: shape, color: color))
    }
}

/// A small key cap such as "⌘1" or "↩".
struct KeyCapLabel: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.07)))
            .contrastEdge(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityHidden(true)
    }
}

import SwiftUI

/// Colours and shared pieces of Duo Slicer's look: teal-to-blue accents on soft cards.
enum Theme {
    static let accent = Color(red: 0.04, green: 0.43, blue: 0.44)
    static let accent2 = Color(red: 0.13, green: 0.36, blue: 0.78)
    static let bed = Color(red: 0.23, green: 0.25, blue: 0.27)
    static let warm = Color(red: 0.96, green: 0.55, blue: 0.20)

    static let gradient = LinearGradient(colors: [Color(red: 0.05, green: 0.58, blue: 0.56), Color(red: 0.14, green: 0.42, blue: 0.86)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
    static let softGradient = LinearGradient(colors: [Color(red: 0.05, green: 0.58, blue: 0.56).opacity(0.16), Color(red: 0.14, green: 0.42, blue: 0.86).opacity(0.10)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
    static let cardRadius: CGFloat = 18
}

/// A rounded card on the grouped background.
struct CardModifier: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

extension View {
    func card(padding: CGFloat = 14) -> some View { modifier(CardModifier(padding: padding)) }
}

/// Small caps title over a card.
struct CardTitle: View {
    let title: String
    var icon: String?
    var trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).foregroundStyle(Theme.accent) }
            Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// A big number with a caption ("1h 20m" / "print time").
struct StatTile: View {
    let value: String
    let label: String
    var icon: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let icon { Image(systemName: icon).font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent) }
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The app's main call to action: white text on the teal-blue gradient.
struct GradientButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var height: CGFloat = 54

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: height)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(enabled ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.gray.opacity(0.45)))
            }
            .shadow(color: enabled ? Theme.accent2.opacity(0.28) : .clear, radius: 10, y: 4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// A selectable tile (quality presets, strength levels).
struct ChoiceTile<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(selected ? AnyShapeStyle(Theme.softGradient) : AnyShapeStyle(Color(.tertiarySystemGroupedBackground)))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 1.5)
                }
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Coloured status capsule ("Ready", "Printing 45%").
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color == .secondary ? Color.secondary : color)
    }
}

/// A filament's colour dot.
struct ColorDot: View {
    let color: Color
    var size: CGFloat = 12

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .overlay(Circle().stroke(Color.primary.opacity(0.18), lineWidth: 0.5))
    }
}

/// The app's mark: a layered cube on the gradient.
struct AppMark: View {
    var size: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Theme.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: "square.stack.3d.up.fill").font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white))
            .shadow(color: Theme.accent2.opacity(0.3), radius: 6, y: 3)
            .accessibilityHidden(true)
    }
}

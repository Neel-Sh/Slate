import SwiftUI

/// Semantic colors from the asset catalog (light, dark, and increased-contrast variants).
/// Ink is the interaction color; ember (`signal`) is reserved for the few things that need attention.
extension Color {
    enum slate {
        static let canvas = Color("Canvas")
        static let surfaceSecondary = Color("SurfaceSecondary")
        static let surfaceElevated = Color("SurfaceElevated")
        static let inkPrimary = Color("InkPrimary")
        static let inkSecondary = Color("InkSecondary")
        static let inkMetadata = Color("InkMetadata")
        /// Controls and selection. Near-black in light mode, near-white in dark mode.
        static let accent = Color("Accent")
        static let onAccent = Color("OnAccent")
        /// Links in message bodies.
        static let link = Color("Link")
        /// Unread and other small attention cues.
        static let signal = Color("Signal")
        static let selectionFill = Color("SelectionFill")
        static let separator = Color("SeparatorDecorative")
        static let destructive = Color("Destructive")
        static let positive = Color("Positive")
        static let warning = Color("Warning")
    }
}

enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let panelRadius: CGFloat = 16
    static let minHit: CGFloat = 44
}

enum Motion {
    /// One quiet curve for everything; no bounce.
    static let standard = Animation.smooth(duration: 0.28)
    static let quick = Animation.smooth(duration: 0.18)
}

/// Quiet, warm label palette. A label's meaning is always carried by its text; color is a secondary cue.
enum ChipTone: String, CaseIterable {
    case ember, amber, sage, mauve, stone

    var ink: Color { Color("Chip\(rawValue.capitalized)Ink") }
    var fill: Color { Color("Chip\(rawValue.capitalized)Fill") }

    /// Maps Gmail label colors (or tone names) onto the restrained palette. Cool hues become neutral stone.
    static func forLabel(_ colorHex: String?, name: String) -> ChipTone {
        if let c = colorHex, let tone = ChipTone(rawValue: c) { return tone }
        guard let hex = colorHex?.trimmingCharacters(in: CharacterSet(charactersIn: "#")), hex.count == 6, let v = Int(hex, radix: 16) else {
            return .stone
        }
        let r = Double((v >> 16) & 0xFF), g = Double((v >> 8) & 0xFF), b = Double(v & 0xFF)
        let maxC = max(r, g, b), minC = min(r, g, b)
        if maxC - minC < 24 { return .stone }
        if r >= g && r >= b { return g > b + 40 ? .amber : (b > g + 20 ? .mauve : .ember) }
        if g >= r && g >= b { return r > b + 40 ? .amber : .sage }
        return r > g + 20 ? .mauve : .stone
    }
}

struct LabelChip: View {
    var text: String
    var tone: ChipTone

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tone.ink)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tone.fill, in: Capsule())
    }
}

/// Small monospaced tag, used for section markers ("01  Focus").
struct Tag: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.caption2.monospaced().weight(.medium))
            .foregroundStyle(Color.slate.inkSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.slate.surfaceSecondary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

struct UnreadDot: View {
    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 8
    var body: some View {
        Circle()
            .fill(Color.slate.signal)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Discreet account identity for unified lists: text first, so it never depends on color.
struct AccountTag: View {
    var account: Account
    var body: some View {
        Text(account.shortLabel)
            .font(.caption)
            .foregroundStyle(Color.slate.inkMetadata)
            .lineLimit(1)
    }
}

/// App-owned panel surface (summary, suggested reply). System sheets and controls keep system geometry.
struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.slate.surfaceSecondary, in: RoundedRectangle(cornerRadius: Spacing.panelRadius, style: .continuous))
    }
}

extension View {
    func panel() -> some View { modifier(PanelBackground()) }
}

// MARK: - Warm gradients

/// The warm palette used for gradients. Kept separate from text tokens: these are decorative only.
enum Warm {
    static let ember = Color(red: 0.95, green: 0.42, blue: 0.23)
    static let coral = Color(red: 0.93, green: 0.30, blue: 0.40)
    static let amber = Color(red: 0.97, green: 0.70, blue: 0.40)
    static let peach = Color(red: 0.99, green: 0.86, blue: 0.74)
    static let blush = Color(red: 0.98, green: 0.82, blue: 0.86)
}

/// A wash of warm light across the top of a screen that fades into the canvas. Decorative only: text never sits on it directly.
/// Drifts slowly; static when Reduce Motion is on.
struct WarmSky: View {
    var palette: [Color]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let dx = Float(sin(t * 0.22)) * 0.10, dy = Float(cos(t * 0.17)) * 0.06
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.45], [0.5 + dx, 0.5 + dy], [1, 0.4],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: palette, smoothsColors: true)
            .opacity(scheme == .dark ? 0.55 : 0.82)
        }
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .accessibilityHidden(true)
    }
}

/// Mark for generated content: a thin warm ring, never a sparkle.
struct AuraRing: View {
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 13
    var body: some View {
        Circle()
            .strokeBorder(AngularGradient(colors: [Warm.ember, Warm.amber, Warm.coral, Warm.ember], center: .center), lineWidth: size * 0.18)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A small header for generated content so it is always distinguishable from the sender's words.
struct GeneratedBadge: View {
    var title: String
    var body: some View {
        HStack(spacing: 6) {
            AuraRing()
            Text(title)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(Color.slate.inkSecondary)
    }
}

// MARK: - Buttons

/// Solid ink capsule — the one primary action on a screen.
struct PrimaryCapsuleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.slate.onAccent)
            .padding(.horizontal, Spacing.xl)
            .frame(minHeight: 50)
            .background(Color.slate.accent.opacity(isEnabled ? 1 : 0.35), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

/// Quiet text-weight action.
struct QuietCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(Color.slate.inkPrimary)
            .padding(.horizontal, Spacing.xl)
            .frame(minHeight: 50)
            .background(Color.slate.surfaceSecondary.opacity(configuration.isPressed ? 1 : 0.001), in: Capsule())
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

/// Row press feedback in app-owned lists.
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.slate.selectionFill : .clear)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

struct EmptyStateView: View {
    var title: String
    var message: String?
    var symbol: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.slate.inkMetadata)
                .padding(.bottom, Spacing.xxs)
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.slate.inkPrimary)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Color.slate.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(QuietCapsuleStyle())
                    .padding(.top, Spacing.xxs)
            }
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: 360)
        .accessibilityElement(children: .combine)
    }
}

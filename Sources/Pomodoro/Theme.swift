import SwiftUI
import AppKit
import PomodoroCore

// MARK: - Palette

/// Soft surfaces on the panel's own glass. Cards are translucent tints rather
/// than solid fills, so the system material shows through and the whole thing
/// follows Light and Dark mode like the other menu bar panels.
enum Theme {
    /// Task names and anything else that leads: pure white on the dark glass.
    /// The system primary label is only ~85% white there, which read as grey.
    static let text = Color.dynamic(light: 0x1D1D1F, dark: 0xFFFFFF)
    /// Supporting times, durations, captions and past rows. Toned down so it
    /// sits well below the white names.
    static let secondaryText = Color.dynamic(light: 0x6A6A70, dark: 0x9A9AA0)
    /// Breaks share the one grey rather than a brighter one of their own.
    static let breakText = secondaryText

    /// Slate blue for links, counts and focus dots. 5:1 or better on a card
    /// in either appearance.
    static let accent = Color.dynamic(light: 0x46618A, dark: 0xAAC0DF)
    /// Orange that reads as text, for "in 12m" warnings and the pause glyph.
    static let warning = Color.dynamic(light: 0xA9520E, dark: 0xF2A65A)
    /// A break's marker in the timeline: a quiet line, so the work stands out.
    static let breakLine = Color.dynamic(light: 0x000000, dark: 0xFFFFFF,
                                         lightOpacity: 0.22, darkOpacity: 0.35)
    /// For the trash glyph. The filled Delete button uses `destructiveFill`.
    static let destructive = Color.dynamic(light: 0xB83A27, dark: 0xFF8A78)
    /// White text on it measures 5:1.
    static let destructiveFill = Color(hex: 0xC2412D)

    /// The active row's rail. Too light to carry text or thin glyphs, so it is
    /// only ever used as a fill.
    static let orange = Color(hex: 0xEC8A33)

    /// A card: a faint lift off the glass.
    static let card = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF,
                                    lightOpacity: 0.45, darkOpacity: 0.06)
    /// Small raised things on a card: buttons, the active row, the editor.
    static let raised = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF,
                                      lightOpacity: 0.8, darkOpacity: 0.13)
    /// The floor of a pressed-in field.
    static let inset = Color.dynamic(light: 0x000000, dark: 0x000000,
                                     lightOpacity: 0.05, darkOpacity: 0.22)
    /// The lit top edge that makes a translucent surface read as glass.
    static let edge = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF,
                                    lightOpacity: 0.75, darkOpacity: 0.14)
    static let shadow = Color.dynamic(light: 0x000000, dark: 0x000000,
                                      lightOpacity: 0.10, darkOpacity: 0.35)
    static let innerShadow = Color.dynamic(light: 0x000000, dark: 0x000000,
                                           lightOpacity: 0.16, darkOpacity: 0.5)
    static let hairline = Color.dynamic(light: 0x000000, dark: 0xFFFFFF,
                                        lightOpacity: 0.10, darkOpacity: 0.10)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// Resolved at draw time against the view's appearance, so it flips with
    /// Light and Dark mode without any view code knowing which is active.
    static func dynamic(
        light: UInt32,
        dark: UInt32,
        lightOpacity: CGFloat = 1,
        darkOpacity: CGFloat = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: isDark ? darkOpacity : lightOpacity
            )
        })
    }
}

// MARK: - Surfaces

extension View {
    /// Lifted off the glass: a translucent tint, a lit top edge and a soft
    /// shade below. `elevation` 1 is a card; smaller values suit rows.
    func raised(
        cornerRadius: CGFloat,
        elevation: CGFloat = 1,
        fill: Color = Theme.card
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fill)
                .shadow(color: Theme.shadow, radius: 10 * elevation, x: 0, y: 4 * elevation)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [Theme.edge, Theme.edge.opacity(0.15)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1
                        )
                )
        )
    }

    /// Pressed into the surface, for fields and the selected row.
    func insetWell(cornerRadius: CGFloat) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.inset)
                // A blurred stroke clipped to the shape, rather than a shape
                // style inner shadow: that one is masked by the fill's alpha,
                // and on a 5% fill it all but disappears.
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Theme.innerShadow, lineWidth: 2)
                        .blur(radius: 1.5)
                        .offset(y: 1)
                        .mask(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                )
        )
    }

    /// A borderless text field sitting in an inset well.
    func insetField(height: CGFloat = 32) -> some View {
        textFieldStyle(.plain)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .frame(height: height)
            .insetWell(cornerRadius: height * 0.36)
    }
}

/// A divider that belongs on the soft surfaces; the system one is too heavy.
struct ThemeDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
    }
}

/// A number box whose placeholder names its unit, so a pair needs no labels.
///
/// Backed by text rather than a number format: a formatted field only hands
/// its value over when the edit is committed (Return, or focus moving), so a
/// duration typed just before clicking Add could be missed. What is typed
/// stays as typed; `DurationInput` reads it, and anything that isn't a number
/// gets a red edge.
struct DurationField: View {
    let unit: DurationInput.Unit
    @Binding var text: String

    var body: some View {
        TextField(unit == .hours ? "Hours" : "Minutes", text: $text)
            .monospacedDigit()
            .insetField(height: 30)
            .overlay {
                if isInvalid {
                    RoundedRectangle(cornerRadius: 30 * 0.36, style: .continuous)
                        .strokeBorder(Theme.destructive, lineWidth: 1)
                }
            }
            .frame(width: 84)
            .help(isInvalid ? (unit == .hours ? "Hours as a number, like 1 or 1.5"
                                              : "Minutes as a whole number, like 25") : "")
    }

    private var isInvalid: Bool {
        !DurationInput.isBlank(text) && DurationInput.minutes(in: text, unit: unit) == nil
    }
}

// MARK: - Buttons

/// The main action: a thin slate outline on a clear background, in the same
/// colour as the links, so the panel's glass shows straight through it.
struct PrimaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, compact: compact)
    }

    private struct Styled: View {
        let configuration: Configuration
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .labelStyle(.titleAndIcon)
                .font(.system(size: compact ? 12 : 13, weight: .semibold))
                // Disabled drops the slate entirely, so it can't be mistaken
                // for a live Start button.
                .foregroundStyle(isEnabled ? Theme.accent : Theme.secondaryText.opacity(0.7))
                .padding(.horizontal, compact ? 14 : 20)
                .frame(height: compact ? 26 : 32)
                // Clear at rest; a faint wash while pressed is the only
                // feedback.
                .background {
                    Capsule().fill(configuration.isPressed ? Theme.accent.opacity(0.15) : Color.clear)
                }
                .overlay {
                    Capsule().strokeBorder(isEnabled ? Theme.accent : Theme.hairline, lineWidth: 1)
                }
                // Without this only the label and rim would take clicks.
                .contentShape(Capsule())
        }
    }
}

/// A soft raised pill (or circle) for everything that isn't the main action.
struct SoftButtonStyle: ButtonStyle {
    var circular = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, circular: circular, compact: compact)
    }

    private struct Styled: View {
        let configuration: Configuration
        let circular: Bool
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled

        private var height: CGFloat { compact ? 26 : 32 }

        var body: some View {
            configuration.label
                .labelStyle(.titleAndIcon)
                .font(.system(size: compact ? 12 : 13, weight: .medium))
                .foregroundStyle(isEnabled ? Theme.text : Theme.secondaryText.opacity(0.6))
                .padding(.horizontal, circular ? 0 : (compact ? 12 : 16))
                .frame(width: circular ? height : nil, height: height)
                // The button stays one view in every state; only what sits
                // behind it changes. Branching the whole label on `isPressed`
                // replaced the view under the pointer on mouse-down, and
                // SwiftUI dropped the click, so these buttons did nothing.
                .background {
                    if !isEnabled {
                        // Just an outline, with no lift to suggest it can be
                        // pressed, but enough that an icon-only button keeps
                        // its shape.
                        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    } else if configuration.isPressed {
                        Color.clear.insetWell(cornerRadius: height / 2)
                    } else {
                        Color.clear.raised(cornerRadius: height / 2, elevation: 0.3, fill: Theme.raised)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
        }
    }
}

/// Plain slate text that acts as a link.
struct TextLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isEnabled ? Theme.accent : Theme.secondaryText.opacity(0.55))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
        }
    }
}

/// Filled red, for the one irreversible action.
struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(Capsule().fill(Theme.destructiveFill))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

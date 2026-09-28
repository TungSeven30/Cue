import SwiftUI

/// Reading preferences from Settings › Appearance. They only change how the
/// app looks — nothing here reaches a `JobSettingsSnapshot` — so they live in
/// `@AppStorage` and are applied once per window root by
/// `cueDisplayPreferences()`. Raw values are persisted; do not rename them.
enum DisplayPreferenceKey {
    static let typography = "displayTypography"
    static let textScale = "displayTextScale"
    static let listDensity = "displayListDensity"
}

/// The system typeface family used across the app. `.system` leaves SwiftUI's
/// default design untouched, so the default renders exactly as before.
enum AppTypography: String, CaseIterable, Identifiable {
    case system
    case rounded
    case serif
    case monospaced

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .monospaced: "Monospaced"
        }
    }

    /// The macOS typeface each option resolves to.
    var typefaceName: String {
        switch self {
        case .system: "SF Pro"
        case .rounded: "SF Pro Rounded"
        case .serif: "New York"
        case .monospaced: "SF Mono"
        }
    }

    /// nil keeps the platform default design.
    var design: Font.Design? {
        switch self {
        case .system: nil
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

/// Text and control size. macOS ignores `dynamicTypeSize` for the built-in
/// text styles (measured on macOS 27: every size renders at the same width),
/// so scaling goes through `cueFont(_:)`, the root body font, and the root
/// control size instead.
enum TextScale: String, CaseIterable, Identifiable {
    case smaller
    case standard
    case large
    case larger
    case largest

    var id: String { rawValue }

    var factor: CGFloat {
        switch self {
        case .smaller: 0.9
        case .standard: 1
        case .large: 1.15
        case .larger: 1.3
        case .largest: 1.5
        }
    }

    var label: String {
        switch self {
        case .smaller: "Smaller"
        case .standard: "Default"
        case .large: "Large"
        case .larger: "Larger"
        case .largest: "Largest"
        }
    }

    var percentLabel: String { "\(Int((factor * 100).rounded()))%" }

    /// Buttons, pickers, and pop-up menus follow the text, so controls never
    /// look undersized next to scaled labels. Views that pin
    /// `.controlSize(.small)` keep it; their `cueFont` text still scales.
    var controlSize: ControlSize {
        switch self {
        case .smaller: .small
        case .standard: .regular
        case .large, .larger, .largest: .large
        }
    }
}

/// How much each row in the job list and the transcript shows.
/// `.comfortable` is the layout Cue always had and must stay pixel-identical.
enum ListDensity: String, CaseIterable, Identifiable {
    case compact
    case comfortable
    case detailed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: "Compact"
        case .comfortable: "Comfortable"
        case .detailed: "Detailed"
        }
    }

    var summary: String {
        switch self {
        case .compact: "One line per row, so more fits on screen."
        case .comfortable: "Name and status on every row."
        case .detailed: "Adds languages, length, and dates."
        }
    }

    /// Rows show their secondary (status) line.
    var showsSecondaryLine: Bool { self != .compact }

    /// Rows show an extra metadata line.
    var showsDetailLine: Bool { self == .detailed }
}

private struct CueTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

private struct CueListDensityKey: EnvironmentKey {
    static let defaultValue: ListDensity = .comfortable
}

extension EnvironmentValues {
    /// Multiplier from Settings › Appearance › Text size; 1 is the default.
    var cueTextScale: CGFloat {
        get { self[CueTextScaleKey.self] }
        set { self[CueTextScaleKey.self] = newValue }
    }

    /// Row density from Settings › Appearance › List density.
    var cueListDensity: ListDensity {
        get { self[CueListDensityKey.self] }
        set { self[CueListDensityKey.self] = newValue }
    }
}

/// Text-style fonts that follow the Text size preference.
enum CueFont {
    /// macOS point sizes of the built-in text styles (Human Interface
    /// Guidelines, macOS typography table).
    static func pointSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline: 13
        case .subheadline: 11
        case .body: 13
        case .callout: 12
        case .footnote: 10
        case .caption: 10
        case .caption2: 10
        @unknown default: 13
        }
    }

    /// At 100% this returns the platform text style itself, so the default
    /// setting renders exactly as `.font(.caption)` and friends always did.
    static func font(
        _ style: Font.TextStyle,
        scale: CGFloat,
        weight: Font.Weight? = nil,
        design: Font.Design? = nil,
        monospacedDigit: Bool = false
    ) -> Font {
        var font: Font
        if abs(scale - 1) < 0.001 {
            font = .system(style, design: design)
        } else {
            let defaultWeight: Font.Weight = style == .headline ? .bold : .regular
            font = .system(size: pointSize(for: style) * scale, weight: defaultWeight, design: design)
        }
        if let weight { font = font.weight(weight) }
        if monospacedDigit { font = font.monospacedDigit() }
        return font
    }
}

private struct CueFontModifier: ViewModifier {
    @Environment(\.cueTextScale) private var scale
    let style: Font.TextStyle
    let weight: Font.Weight?
    let design: Font.Design?
    let monospacedDigit: Bool

    func body(content: Content) -> some View {
        content.font(
            CueFont.font(style, scale: scale, weight: weight, design: design, monospacedDigit: monospacedDigit)
        )
    }
}

private struct DisplayPreferencesModifier: ViewModifier {
    @AppStorage(DisplayPreferenceKey.typography) private var typography: AppTypography = .system
    @AppStorage(DisplayPreferenceKey.textScale) private var textScale: TextScale = .standard
    @AppStorage(DisplayPreferenceKey.listDensity) private var listDensity: ListDensity = .comfortable

    func body(content: Content) -> some View {
        content
            // nil at 100% keeps every list's and form's own default font.
            .font(textScale == .standard ? nil : CueFont.font(.body, scale: textScale.factor))
            .fontDesign(typography.design)
            .controlSize(textScale.controlSize)
            .environment(\.cueTextScale, textScale.factor)
            .environment(\.cueListDensity, listDensity)
    }
}

extension View {
    /// `.font(.caption)` that follows Settings › Appearance › Text size. Use
    /// it for every text-style font; keep fixed `.system(size:)` fonts only
    /// for glyphs whose size is not text (video overlays, hero icons).
    func cueFont(
        _ style: Font.TextStyle,
        weight: Font.Weight? = nil,
        design: Font.Design? = nil,
        monospacedDigit: Bool = false
    ) -> some View {
        modifier(CueFontModifier(style: style, weight: weight, design: design, monospacedDigit: monospacedDigit))
    }

    /// Applies the Appearance preferences to a scene's content. Call once per
    /// scene root (main window, Settings); sheets and popovers inherit it.
    func cueDisplayPreferences() -> some View {
        modifier(DisplayPreferencesModifier())
    }
}

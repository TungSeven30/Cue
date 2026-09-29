import AppKit
import SwiftUI

/// The three reading preferences as one value, so "Restore Defaults" and its
/// enabled state have a single definition. The defaults match the
/// `@AppStorage` defaults the window roots apply in `DisplayPreferences.swift`.
struct AppearanceSelection: Equatable {
    var typography: AppTypography
    var textScale: TextScale
    var listDensity: ListDensity

    static let defaults = AppearanceSelection(typography: .system, textScale: .standard, listDensity: .comfortable)

    var isDefault: Bool { self == .defaults }
}

/// Typeface, text size, and list density. Each control writes the
/// `DisplayPreferenceKey` value it names; the Settings window and every other
/// Cue window follow through `cueDisplayPreferences()`, so changes apply live.
struct AppearanceSettingsPane: View {
    @AppStorage(DisplayPreferenceKey.typography) private var typography: AppTypography = .system
    @AppStorage(DisplayPreferenceKey.textScale) private var textScale: TextScale = .standard
    @AppStorage(DisplayPreferenceKey.listDensity) private var listDensity: ListDensity = .comfortable

    private var selection: AppearanceSelection {
        get { AppearanceSelection(typography: typography, textScale: textScale, listDensity: listDensity) }
        nonmutating set {
            typography = newValue.typography
            textScale = newValue.textScale
            listDensity = newValue.listDensity
        }
    }

    var body: some View {
        SettingsPaneScaffold(
            pane: .appearance,
            trailing: {
                Button("Restore Defaults") { selection = .defaults }
                    .disabled(selection.isDefault)
                    .help("Use SF Pro, Default text size, and Comfortable rows")
            },
            content: {
                typefaceSection
                textSizeSection
                densitySection
                previewSection
            }
        )
    }

    private var typefaceSection: some View {
        Section {
            TypefacePicker(selection: $typography)
        } header: {
            SettingsSectionHeader("Typeface")
        }
    }

    private var textSizeSection: some View {
        Section {
            HStack(spacing: 10) {
                Text("A")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Picker("Text size", selection: $textScale) {
                    ForEach(TextScale.allCases) { scale in
                        Text(scale.percentLabel).tag(scale)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text("A")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
        } header: {
            SettingsSectionHeader("Text size")
        } footer: {
            SettingsFootnote(
                "Also scales buttons and pop-up menus in Cue's windows. Menus in the macOS menu bar follow your system settings."
            )
        }
    }

    private var densitySection: some View {
        Section {
            Picker("List density", selection: $listDensity) {
                ForEach(ListDensity.allCases) { density in
                    Text(density.label).tag(density)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
        } header: {
            SettingsSectionHeader("List density")
        } footer: {
            SettingsFootnote(listDensity.summary)
        }
    }

    private var previewSection: some View {
        Section {
            AppearancePreviewCard(selection: selection)
        } header: {
            SettingsSectionHeader("Preview")
        }
    }
}

// MARK: - Typeface

/// Every typeface shown in its own design. Four across when the pane is wide
/// enough for their natural widths, two by two or stacked when it is not, so a
/// large text size wraps the picker instead of clipping it. The tile text
/// never compresses (`fixedSize`): `ViewThatFits` then judges each layout by
/// the widths the names really need, instead of accepting a four-across row
/// whose names would break mid-word.
private struct TypefacePicker: View {
    @Binding var selection: AppTypography

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                ForEach(AppTypography.allCases) { tile($0) }
            }
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    tile(.system)
                    tile(.rounded)
                }
                HStack(spacing: 10) {
                    tile(.serif)
                    tile(.monospaced)
                }
            }
            VStack(spacing: 10) {
                ForEach(AppTypography.allCases) { tile($0) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Typeface")
    }

    private func tile(_ option: AppTypography) -> some View {
        TypefaceTile(option: option, isSelected: option == selection) {
            selection = option
        }
    }
}

private struct TypefaceTile: View {
    let option: AppTypography
    let isSelected: Bool
    let select: () -> Void

    /// An explicit `.default` (not nil), so the System tile stays SF Pro while
    /// the window itself is set to another typeface. The tile also sets
    /// `fontDesign` to it: the window's own `fontDesign` reaches every Text
    /// below it and wins over a design named on the font, so without this all
    /// four tiles would draw in whichever typeface is currently chosen.
    private var design: Font.Design { option.design ?? .default }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top) {
                    Text("Aa")
                        .font(.system(size: 26, design: design))
                        .accessibilityHidden(true)
                    Spacer(minLength: 4)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                }
                Text(option.label)
                    .cueFont(.body, weight: .medium, design: design)
                    .fixedSize(horizontal: true, vertical: false)
                Text(option.typefaceName)
                    .cueFont(.caption, design: design)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .fontDesign(design)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.label), \(option.typefaceName)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Preview

/// A job row and a subtitle line, set the way the real sidebar and transcript
/// will be. It applies the selection itself instead of reading the window's
/// environment, so it is correct in isolation and on the frame the choice
/// changes.
struct AppearancePreviewCard: View {
    let selection: AppearanceSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PreviewJobRow(
                title: "Interview, take 3.mov",
                status: .transcribing,
                statusText: "Transcribing… 42%",
                detail: "Japanese · 1:24:07 · Sep 27",
                progress: 0.42
            )
            Divider()
                .padding(.vertical, 4)
            PreviewSubtitleLine()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        .environment(\.cueTextScale, selection.textScale.factor)
        .environment(\.cueListDensity, selection.listDensity)
        .fontDesign(selection.typography.design ?? .default)
        .font(selection.textScale == .standard ? nil : CueFont.font(.body, scale: selection.textScale.factor))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sample job list and subtitle in the chosen typeface, text size, and density")
    }
}

/// A job row as the sidebar draws it: the status icon and name always, the
/// status line from Comfortable up, the metadata line only when Detailed.
private struct PreviewJobRow: View {
    @Environment(\.cueListDensity) private var density
    let title: String
    let status: JobStatus
    let statusText: String
    let detail: String
    let progress: Double

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.systemImage)
                .foregroundStyle(status.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                if density.showsSecondaryLine {
                    Text(statusText)
                        .cueFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if density.showsDetailLine {
                    Text(detail)
                        .cueFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            ProgressView(value: progress)
                .frame(width: 36)
        }
        .padding(.vertical, density == .compact ? 2 : 4)
    }
}

/// One cue as the transcript draws it: number, time range, text.
private struct PreviewSubtitleLine: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("12")
                    .cueFont(.caption, weight: .semibold, monospacedDigit: true)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Label(
                    "\(SubtitleWriter.formatDisplayTimestamp(84.3)) – \(SubtitleWriter.formatDisplayTimestamp(87.05))",
                    systemImage: "clock"
                )
                .cueFont(.caption, monospacedDigit: true)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
            Text("Every subtitle you read follows the typeface and size you pick here.")
                .cueFont(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

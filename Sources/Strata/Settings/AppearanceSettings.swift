import SwiftUI

/// Settings ▸ Appearance: color themes, light or dark, row spacing and the size of file names.
struct AppearanceSettings: View {
    @State private var theme = Prefs.shared.theme
    @State private var colors = Prefs.shared.colorThemeOptions
    @State private var density = Prefs.shared.density
    @State private var size = Prefs.shared.nameTextSize
    @State private var alternatingRows = Prefs.shared.alternatingRows
    @State private var previews = Prefs.shared.showIconPreviews

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: Binding(get: { theme }, set: { theme = $0; Prefs.shared.theme = $0 })) {
                    Text("Match the System").tag(0)
                    Text("Light").tag(1)
                    Text("Dark").tag(2)
                }
                .pickerStyle(.radioGroup)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Color theme", comment: "Settings ▸ Appearance: the browser’s color palette")
                    LazyVGrid(columns: Array(repeating: SwiftUI.GridItem(.flexible()), count: 3), spacing: 12) {
                        ForEach(ColorTheme.allCases, id: \.self) { palette in
                            Button {
                                colors.palette = palette
                                Prefs.shared.colorThemeOptions = colors
                            } label: {
                                ThemePreview(palette: palette, selected: colors.palette == palette, options: colors)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(palette.title)
                            .accessibilityAddTraits(colors.palette == palette ? .isSelected : [])
                        }
                    }
                }
                .padding(.vertical, 6)
                Picker("Window tint", selection: Binding(get: { colors.tintsWindow }, set: {
                    colors.tintsWindow = $0
                    Prefs.shared.colorThemeOptions = colors
                })) {
                    Text("Off", comment: "Window tint setting").tag(false)
                    Text("On").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(colors.palette == .system)
            }
            Section("Files") {
                Picker("Density", selection: Binding(get: { density }, set: { density = $0; Prefs.shared.density = $0 })) {
                    Text("Compact").tag(0)
                    Text("Regular").tag(1)
                    Text("Spacious").tag(2)
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Text size")
                    Slider(value: Binding(get: { size }, set: { size = $0.rounded(); Prefs.shared.nameTextSize = $0.rounded() }), in: 11...16, step: 1) {
                        Text("Text size")
                    } minimumValueLabel: {
                        Text(verbatim: "A").font(.system(size: 10))
                    } maximumValueLabel: {
                        Text(verbatim: "A").font(.system(size: 16))
                    }
                    // The row has its own label; the slider's is for VoiceOver only.
                    .labelsHidden()
                    Text("\(Int(size)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
                Text("Quarterly Report.pdf", comment: "Settings ▸ Appearance: a sample file name showing the text size")
                    .font(.system(size: size))
                    .padding(.vertical, [2.0, 5.0, 9.0][min(max(density, 0), 2)])
                    .accessibilityLabel("Preview of a file name at this size")
                Toggle("Alternating row colors", isOn: Binding(get: { alternatingRows }, set: { alternatingRows = $0; Prefs.shared.alternatingRows = $0 }))
                Toggle(isOn: Binding(get: { previews }, set: { previews = $0; Prefs.shared.showIconPreviews = $0 })) {
                    Text("Show icon previews")
                    Text("Pictures, documents and movies show a thumbnail of their contents in place of their icon.")
                }
                Text("Applies to the list, columns and icons in every window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .modifier(ThemedFormBackground())
        // ⌘+ / ⌘− in the list change the size while this is open.
        .onReceive(NotificationCenter.default.publisher(for: .appearanceChanged)) { _ in
            if size != Prefs.shared.nameTextSize { size = Prefs.shared.nameTextSize }
            if theme != Prefs.shared.theme { theme = Prefs.shared.theme }
        }
        .onReceive(Prefs.shared.notifications.publisher(for: .alternatingRowsChanged, object: Prefs.shared)) { _ in alternatingRows = Prefs.shared.alternatingRows }
        .onReceive(NotificationCenter.default.publisher(for: .colorThemeChanged)) { _ in colors = Prefs.shared.colorThemeOptions }
    }
}

/// A miniature native window shows the palette without touching any files or thumbnails.
struct ThemePreview: View {
    let palette: ColorTheme
    let selected: Bool
    let options: ColorThemeOptions
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var appearance: NSAppearance {
        let dark = colorScheme == .dark
        return NSAppearance(named: contrast == .increased
                            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
                            : (dark ? .darkAqua : .aqua)) ?? .currentDrawing()
    }

    var body: some View {
        let chosen = previewOptions
        let chrome = surface(.chrome), sidebar = surface(.sidebar), inspector = surface(.inspector), content = surface(.content)
        let accent = Color(nsColor: chosen.accentColor(highContrast: contrast == .increased))
        VStack(spacing: 6) {
            VStack(spacing: 0) {
                HStack(spacing: 3) {
                    ForEach(0..<3) { _ in Circle().fill(.secondary.opacity(0.35)).frame(width: 4, height: 4) }
                    Spacer()
                }
                .padding(7)
                .background(Color(nsColor: .windowBackgroundColor).overlay(chrome))
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(0..<3) { index in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(index == 0 ? accent.opacity(0.25) : .secondary.opacity(0.15))
                                .frame(height: 4)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    .frame(width: 34)
                    .background(Color(nsColor: .windowBackgroundColor).overlay(sidebar))
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(nsColor: chosen.selectionColor(highContrast: contrast == .increased))).frame(height: 7)
                        ForEach(0..<2) { _ in
                            RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.15)).frame(height: 4)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(7)
                    .frame(maxWidth: .infinity)
                    .background(content)
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.2)).frame(height: 12)
                        ForEach(0..<2) { _ in RoundedRectangle(cornerRadius: 1).fill(.secondary.opacity(0.15)).frame(height: 3) }
                        Spacer(minLength: 0)
                    }
                    .padding(5)
                    .frame(width: 27)
                    .background(Color(nsColor: .windowBackgroundColor).overlay(inspector))
                }
                .frame(height: 46)
                Rectangle().fill(chrome).frame(height: 7)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? accent : .secondary.opacity(0.3),
                                                                  lineWidth: selected ? 2 : 1))
            HStack(spacing: 4) {
                Text(palette.title)
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
            }
            .font(.caption)
            .foregroundStyle(.primary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
    }

    private var previewOptions: ColorThemeOptions {
        var chosen = options
        chosen.palette = palette
        return chosen
    }

    private func surface(_ role: ThemeSurfaceRole) -> Color {
        Color(nsColor: previewOptions.surfaceColor(in: appearance, reduceTransparency: reduceTransparency,
                                                   highContrast: contrast == .increased, role: role))
    }
}

import AppKit
import SwiftUI

/// Colours of the settings window: monochrome, graphite on white in the
/// light appearance and white on graphite in the dark one, with the cards a
/// step lighter than the page in both.
enum SettingsStyle {
    /// Switches, sliders, prominent buttons, the selected segment and the
    /// selected sidebar row.
    static let ink = dynamic(light: NSColor(white: 0.17, alpha: 1), dark: NSColor(white: 0.96, alpha: 1))
    /// Text and knobs on `ink`.
    static let onInk = dynamic(light: .white, dark: NSColor(white: 0.13, alpha: 1))
    /// A section: the title, the card of rows and the footer.
    static let section = dynamic(light: NSColor(white: 0.975, alpha: 1), dark: NSColor(white: 1, alpha: 0.045))
    /// The card of rows inside a section.
    static let card = dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.06))
    static let hairline = Color.primary.opacity(0.07)
    /// Behind small things on a card: key caps, badges, icons, segments.
    static let fill = Color.primary.opacity(0.06)
    /// Behind the indicator preview: light in light, graphite in dark.
    static let preview = dynamic(light: NSColor(white: 0.93, alpha: 1), dark: NSColor(white: 0.1, alpha: 1))

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

extension View {
    /// The window's controls in `ink`: tints, and switches that invert with
    /// the appearance.
    func settingsTheme() -> some View {
        tint(SettingsStyle.ink)
            .toggleStyle(SettingsSwitchStyle())
    }

    /// The selected sidebar row or segment, filled with `ink`.
    func settingsSelection(_ isSelected: Bool, cornerRadius: CGFloat) -> some View {
        foregroundStyle(isSelected ? SettingsStyle.onInk : Color.primary)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(SettingsStyle.ink)
                }
            }
            .contentShape(.rect)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One page of the settings window: the pane's large title, the line about
/// it, and its sections.
struct SettingsPage<Content: View>: View {
    let pane: SettingsPane
    @ViewBuilder let content: Content

    init(_ pane: SettingsPane, @ViewBuilder content: () -> Content) {
        self.pane = pane
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(pane.title)
                        .font(.system(size: 28, weight: .bold))

                    Text(pane.subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A titled card of rows, with an optional note under it. Each row gets the
/// row padding and a line above it, except the first.
struct SettingsSection<Content: View>: View {
    let title: String
    let footer: String?
    @ViewBuilder let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            // A private API, but the only way to reach a section's rows on
            // macOS 14; `ForEach(subviews:)` replaces it from macOS 15.
            _VariadicView.Tree(Rows()) {
                content
            }
            .background(SettingsStyle.card, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(SettingsStyle.hairline)
            }

            if let footer {
                Text(footer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .padding(14)
        .background(SettingsStyle.section, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(SettingsStyle.hairline)
        }
    }

    private struct Rows: _VariadicView_MultiViewRoot {
        func body(children: _VariadicView.Children) -> some View {
            VStack(spacing: 0) {
                ForEach(children) { child in
                    if child.id != children.first?.id {
                        Divider()
                            .padding(.leading, 14)
                    }
                    child
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// A row with an optional icon, a title and an optional line under it on the
/// left, and a control or value on the right.
struct SettingsRow<Accessory: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    var subtitle: String?
    var icon: String?
    @ViewBuilder let accessory: Accessory

    init(_ title: String, subtitle: String? = nil, icon: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                SettingsIcon(systemName: icon)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)

                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // A disabled row reads as disabled, not just its control.
            .opacity(isEnabled ? 1 : 0.45)

            Spacer(minLength: 12)

            accessory
        }
    }
}

struct SettingsToggle: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
        }
    }
}

/// A switch drawn in `ink`, so it inverts with the appearance: graphite
/// with a white knob in light, white with a graphite knob in dark. The
/// system switch keeps a white knob, which a white track would hide.
struct SettingsSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn

        // A button, so the keyboard can reach it too.
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(isOn ? SettingsStyle.ink : Color.primary.opacity(0.14))
                .frame(width: 40, height: 24)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(isOn ? SettingsStyle.onInk : .white)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                        .padding(2.5)
                }
                .animation(.snappy(duration: 0.2), value: isOn)
                .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) {
                configuration.label
            }
        }
    }
}

/// The main action of a row, in `ink`: "Reset…", "Allow…".
struct SettingsProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(SettingsStyle.onInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(SettingsStyle.ink, in: .rect(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}

extension ButtonStyle where Self == SettingsProminentButtonStyle {
    static var settingsProminent: SettingsProminentButtonStyle { SettingsProminentButtonStyle() }
}

/// Segments for a few choices, the selected one in `ink`. The system
/// control writes the selected label in white, which a white segment would
/// hide.
struct SettingsSegmentedPicker<Value: Hashable>: View {
    /// What VoiceOver calls the choice: "Animation", "Language".
    let label: String
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .settingsSelection(option == selection, cornerRadius: 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(SettingsStyle.fill, in: .rect(cornerRadius: 8, style: .continuous))
        .animation(.snappy(duration: 0.2), value: selection)
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(title(option)).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

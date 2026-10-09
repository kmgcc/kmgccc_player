//
//  CapsulePicker.swift
//  myPlayer2
//
//  kmgccc_player - Reusable Capsule-style Picker Component
//

import SwiftUI

/// A reusable capsule-style picker with buttons inside a capsule container.
/// Matches the Liquid Glass aesthetic used throughout the app.
/// Positions setting label on the left and options right-aligned on the right.
struct CapsulePicker<Option: Hashable, Value: Hashable>: View {
    let label: String
    let options: [Option]
    let optionID: (Option) -> Value
    let displayName: (Option) -> String
    @Binding var selection: Value
    var accentColor: Color? = nil

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.settingsAppForegroundColors) private var appColors

    /// Initializer for Identifiable options where selection is Option.ID
    init(
        label: String,
        options: [Option],
        displayName: @escaping (Option) -> String,
        selection: Binding<Value>,
        accentColor: Color? = nil
    ) where Option: Identifiable, Option.ID == Value {
        self.label = label
        self.options = options
        self.optionID = { $0.id }
        self.displayName = displayName
        self._selection = selection
        self.accentColor = accentColor
    }

    /// Initializer for self-identified options where Option == Value (e.g. Enums, Strings)
    init(
        label: String,
        options: [Option],
        selection: Binding<Value>,
        displayName: @escaping (Option) -> String = { "\($0)" },
        accentColor: Color? = nil
    ) where Option == Value {
        self.label = label
        self.options = options
        self.optionID = { $0 }
        self.displayName = displayName
        self._selection = selection
        self.accentColor = accentColor
    }

    private var resolvedAccentColor: Color {
        accentColor ?? themeStore.accentColor
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .settingsRowLabelStyle()

            Spacer()

            SlidingSelector(
                segments: options.map(optionID),
                selection: $selection,
                hSpacing: 0,
                background: {
                    Color.clear
                },
                knob: {
                    Capsule()
                        .fill(resolvedAccentColor.opacity(0.18))
                },
                content: { id, isSelected in
                    let title = options.first(where: { optionID($0) == id }).map(displayName) ?? ""
                    Text(title)
                        .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(isSelected ? resolvedAccentColor : (appColors?.secondary ?? .secondary))
                }
            )
            .padding(3)
            .background(
                Capsule()
                    .fill((appColors?.secondary ?? .secondary).opacity(0.08))
            )
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

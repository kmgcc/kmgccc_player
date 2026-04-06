//
//  CapsulePicker.swift
//  myPlayer2
//
//  kmgccc_player - Reusable Capsule-style Picker Component
//

import SwiftUI

/// A reusable capsule-style picker with buttons inside a capsule container.
/// Matches the Liquid Glass aesthetic used throughout the app.
struct CapsulePicker<T: Hashable & Identifiable>: View where T.ID: Hashable {
    let label: String
    let options: [T]
    let displayName: (T) -> String
    @Binding var selection: T.ID
    let accentColor: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 4) {
                ForEach(options) { option in
                    CapsulePickerButton(
                        title: displayName(option),
                        isSelected: selection == option.id,
                        accentColor: accentColor
                    ) {
                        selection = option.id
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }
}

/// Individual button inside CapsulePicker.
struct CapsulePickerButton: View {
    let title: String
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .background(
            Capsule()
                .fill(isSelected ? accentColor.opacity(0.18) : Color.clear)
        )
        .foregroundStyle(isSelected ? accentColor : .secondary)
    }
}
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

            SlidingSelector(
                segments: options.map(\.id),
                selection: $selection,
                animation: .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08),
                hSpacing: 0,
                background: {
                    Color.clear
                },
                knob: {
                    Capsule()
                        .fill(accentColor.opacity(0.18))
                },
                content: { id, isSelected in
                    let title = options.first(where: { $0.id == id }).map(displayName) ?? ""
                    Text(title)
                        .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(isSelected ? accentColor : .secondary)
                }
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.08))
            )
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

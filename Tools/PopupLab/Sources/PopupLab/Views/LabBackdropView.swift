import SwiftUI

/// Context for inspecting refraction; this belongs to the lab, outside PopupKit.
struct LabBackdropView: View {
    let model: LabModel

    var body: some View {
        ZStack {
            model.palette.secondary.opacity(0.04)
            switch model.backdrop {
            case .plain:
                Color.clear
            case .color:
                LinearGradient(
                    colors: [model.accent.color.opacity(0.55), .cyan.opacity(0.12), .orange.opacity(0.35)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(model.accent.color.opacity(0.35))
                    .frame(width: 300)
                    .offset(x: -120, y: 110)
                Circle()
                    .fill(Color.teal.opacity(0.3))
                    .frame(width: 240)
                    .offset(x: 170, y: -120)
            case .contrast:
                HStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { index in
                        model.palette.primary.opacity(index.isMultiple(of: 2) ? 0.02 : 0.22)
                    }
                }
                .rotationEffect(.degrees(-20))
                .scaleEffect(1.6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }
}

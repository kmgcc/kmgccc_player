import SwiftUI

/// Settings navigation rows share the same typography, hit area and capsule style.
struct SettingsSubpageLink: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    let page: SettingsSubpage

    @Environment(\.navigateSettingsSubpage) private var navigate

    var body: some View {
        Button {
            navigate(page)
        } label: {
            HStack(spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.title3)
                        .settingsDescriptionStyle()
                        .frame(width: 28)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).settingsRowLabelStyle()
                    if let subtitle { Text(subtitle).settingsDescriptionStyle() }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .settingsDescriptionStyle()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Capsule())
        }
        .audioDSPCapsuleButtonStyle()
    }
}

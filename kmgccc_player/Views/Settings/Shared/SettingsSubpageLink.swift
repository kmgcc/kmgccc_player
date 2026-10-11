import SwiftUI

/// Settings navigation rows share the same typography, hit area and capsule style.
struct SettingsSubpageLink: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    let page: SettingsSubpage

    @Environment(\.navigateSettingsSubpage) private var navigate
    @Environment(\.settingsAppForegroundColors) private var appColors
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    var body: some View {
        Button {
            navigate(page)
        } label: {
            HStack(spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.title3)
                        .foregroundStyle(presentationStyle.settingsSecondaryTextColor(appColors: appColors))
                        .frame(width: 28)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).settingsRowLabelStyle()
                    if let subtitle { Text(subtitle).settingsDescriptionStyle() }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(presentationStyle.settingsSecondaryTextColor(appColors: appColors))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Capsule())
        }
        .audioDSPCapsuleButtonStyle()
    }
}

import SwiftUI

@MainActor
struct AudioDSPDeviceSettingsView: View {
    @EnvironmentObject private var appSession: AppSessionHost
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var isUpdating = false

    private var controller: AudioDSPDeviceController { appSession.audioDSPDeviceController }
    private var dsp: AudioDSPController { appSession.audioDSPController }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsStyleTokens.sectionSpacing) {
                SettingsHeaderLabel("设备音效", systemImage: "headphones")
                SettingsSection {
                    SettingsSwitchRow(title: "按设备切换音效", isOn: Binding(
                        get: { controller.settings.enabled },
                        set: { controller.setEnabled($0) }
                    ))
                }
                defaultSection
                devicesSection
                if let error = dsp.lastError {
                    SettingsSection {
                        Label(error.message, systemImage: "exclamationmark.circle")
                            .settingsDescriptionStyle()
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 66)
            .padding(.bottom, 40)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(themeStore.accentColor)
        .task {
            await controller.ensureLoaded()
            controller.refreshDevices()
        }
    }

    private var defaultSection: some View {
        SettingsSection("未指定音效的设备") {
            HStack(spacing: 12) {
                Text("默认音效").settingsRowLabelStyle()
                Spacer(minLength: 16)
                presetMenu(
                    title: "默认音效", selectedID: controller.settings.defaultPresetID,
                    emptyTitle: "关闭音效", deviceUID: nil, isDefault: true
                ) { id in
                    update { try await controller.setDefaultPreset(id) }
                }
            }
        }
    }

    private var devicesSection: some View {
        SettingsSection("输出设备") {
            if controller.devices.isEmpty {
                Text("暂无输出设备").settingsDescriptionStyle()
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(controller.devices) { device in
                        deviceRow(device)
                    }
                }
            }
        }
    }

    private func deviceRow(_ device: DSPOutputDevice) -> some View {
        HStack(spacing: 14) {
            Image(systemName: device.symbolName)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(themeStore.accentColor.opacity(device.isConnected ? 0.85 : 0.45))
                .frame(width: 44, height: 44)
                .background(themeStore.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .settingsRowLabelStyle()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(device.name)
                if device.id == controller.currentOutputDeviceUID {
                    Text("当前输出").settingsDescriptionStyle()
                } else if !device.isConnected {
                    Text("已断开").settingsDescriptionStyle()
                }
            }
            Spacer(minLength: 12)
            presetMenu(
                title: "\(device.name)的音效", selectedID: controller.settings.bindings[device.id]?.presetID,
                emptyTitle: "未指定", deviceUID: device.id, isDefault: false
            ) { id in
                update { try await controller.bindPreset(id, to: device) }
            }
        }
    }

    private func presetMenu(
        title: String, selectedID: UUID?, emptyTitle: String, deviceUID: String?, isDefault: Bool,
        select: @escaping (UUID?) -> Void
    ) -> some View {
        let selectedName = dsp.presets.first(where: { $0.presetID == selectedID })?.name ?? emptyTitle
        return Menu {
            Button { select(nil) } label: {
                menuOptionLabel(emptyTitle, isSelected: selectedID == nil)
            }
            ForEach(dsp.presets) { preset in
                presetOption(preset, selectedID: selectedID, deviceUID: deviceUID, isDefault: isDefault, select: select)
            }
        } label: {
            Text(selectedName)
                .settingsRowLabelStyle()
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .audioDSPCapsuleButtonStyle()
        .frame(width: 240)
        .disabled(!controller.isLoaded)
        .accessibilityLabel(title)
        .help(selectedName)
    }

    @ViewBuilder
    private func menuOptionLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func presetOption(
        _ preset: DSPPresetDocument, selectedID: UUID?, deviceUID: String?, isDefault: Bool,
        select: @escaping (UUID?) -> Void
    ) -> some View {
        let isSelectedDefault = isDefault && controller.settings.defaultPresetID == preset.presetID
        let owner = isSelectedDefault ? nil : controller.presetOwner(preset.presetID, excluding: deviceUID)
        var candidate = preset.configuration
        candidate.enabled = true
        let incompatible = (try? dsp.validate(candidate)) == nil
        let suffix = owner.map { "（\($0)）" } ?? (incompatible ? "（不兼容）" : "")
        return Button { select(preset.presetID) } label: {
            menuOptionLabel(preset.name + suffix, isSelected: selectedID == preset.presetID)
        }
        .disabled(owner != nil || incompatible)
    }

    private func update(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isUpdating else { return }
        isUpdating = true
        Task {
            defer { isUpdating = false }
            do { try await operation() }
            catch { dsp.report(error: error) }
        }
    }
}

//
//  AudioDSPDeviceSettingsView.swift
//  myPlayer2
//
//  Output device chooser at the left of 音效与设备. It picks whose sound the
//  page shows; only the device now playing can be edited.
//

import PopupKit
import SwiftUI

struct AudioDSPDevicePicker: View {
    let devices: [DSPOutputDevice]
    let currentID: String?
    /// The device shown; nil follows the device now playing.
    @Binding var selectedID: String?
    let presetName: (DSPOutputDevice) -> String

    @EnvironmentObject private var themeStore: ThemeStore
    @State private var isOpen = false

    private var shown: DSPOutputDevice? {
        devices.first { $0.id == (selectedID ?? currentID) }
    }

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            VStack(spacing: 8) {
                AudioDSPDeviceIcon(symbolName: shown?.symbolName ?? "hifispeaker", size: 56)
                // The padding keeps the name centered while reserving room for
                // the chevron at its trailing edge.
                Text(shown?.name ?? "未识别输出设备")
                    .settingsRowLabelStyle()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 14)
                    .overlay(alignment: .trailing) {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(themeStore.appForegroundPalette.tertiaryColor)
                    }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(devices.isEmpty)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            AppPopupScrollRegion(height: min(320, CGFloat(devices.count) * 72 + 20)) {
                LazyVStack(alignment: .leading, spacing: AppPopupStyle().rowSpacing) {
                    ForEach(devices) { device in
                        AudioDSPDevicePickerRow(
                            device: device,
                            subtitle: presetName(device),
                            isSelected: device.id == shown?.id
                        ) {
                            selectedID = device.id == currentID ? nil : device.id
                            isOpen = false
                        }
                    }
                }
            }
            .padding(AppPopupStyle().rowPadding)
            .frame(width: 340)
            .appPopupAppearance()
        }
        .accessibilityLabel("输出设备")
        .accessibilityValue(shown?.name ?? "")
    }
}

private struct AudioDSPDevicePickerRow: View {
    let device: DSPOutputDevice
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AudioDSPDeviceIcon(symbolName: device.symbolName, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name)
                        .font(.system(size: AppPopupStyle().bodySize, weight: .medium))
                        .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(themeStore.accentColor)
                }
            }
            .padding(AppPopupStyle().rowPadding)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(rowFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovered = $0 }
        .help(device.name)
    }

    private var rowFill: Color {
        if isSelected { return themeStore.accentColor.opacity(0.12) }
        return isHovered ? themeStore.appForegroundPalette.primaryColor.opacity(0.06) : .clear
    }
}

private struct AudioDSPDeviceIcon: View {
    let symbolName: String
    let size: CGFloat

    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: size * 0.5, weight: .regular))
            .foregroundStyle(themeStore.accentColor.opacity(0.85))
            .frame(width: size, height: size)
            .background(
                themeStore.accentColor.opacity(0.08),
                in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

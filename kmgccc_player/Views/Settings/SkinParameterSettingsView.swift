import SwiftUI

struct SkinParameterSettingsView: View {
    let skinID: String
    let surface: SkinSurface
    let definitions: [SkinParameterDefinition]
    let store: SkinParameterStore

    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @EnvironmentObject private var themeStore: ThemeStore

    private var visibleDefinitions: [SkinParameterDefinition] {
        definitions.filter { $0.isUserVisible && $0.surfaces.contains(surface) }
    }

    var body: some View {
        let _ = store.revision
        VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
            ForEach(visibleDefinitions) { definition in
                parameterRow(definition)
            }
        }
    }

    @ViewBuilder
    private func parameterRow(_ definition: SkinParameterDefinition) -> some View {
        switch definition.control {
        case .toggle:
            SettingsSwitchRow(
                title: definition.title,
                isOn: Binding(
                    get: { booleanValue(store.value(skinID: skinID, surface: surface, definition: definition)) },
                    set: { set(definition, value: .boolean($0)) }
                )
            )
        case .range(let minimum, let maximum, let step):
            rangeRow(definition, minimum: minimum, maximum: maximum, step: step)
        case .choice(let choices):
            CapsulePicker(
                label: definition.title,
                options: choices,
                displayName: \.title,
                selection: Binding(
                    get: { textValue(store.value(skinID: skinID, surface: surface, definition: definition), choices: choices) },
                    set: { set(definition, value: .text($0)) }
                ),
                accentColor: themeStore.accentColor
            )
        }
    }

    private func rangeRow(
        _ definition: SkinParameterDefinition,
        minimum: Double,
        maximum: Double,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: presentationStyle.compactInlineSpacing) {
            HStack {
                Text(definition.title)
                    .settingsRowLabelStyle()
                Spacer(minLength: 12)
                Text(numberValue(store.value(skinID: skinID, surface: surface, definition: definition)), format: .number)
                    .font(presentationStyle.captionFont)
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { numberValue(store.value(skinID: skinID, surface: surface, definition: definition)) },
                    set: { set(definition, value: .number($0)) }
                ),
                in: minimum...maximum,
                step: step
            )
            .tint(themeStore.accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func set(_ definition: SkinParameterDefinition, value: SkinParameterValue) {
        store.set(skinID: skinID, surface: surface, definition: definition, value: value)
    }

    private func booleanValue(_ value: SkinParameterValue) -> Bool {
        guard case .boolean(let value) = value else { return false }
        return value
    }

    private func numberValue(_ value: SkinParameterValue) -> Double {
        guard case .number(let value) = value else { return 0 }
        return value
    }

    private func textValue(_ value: SkinParameterValue, choices: [SkinParameterDefinition.Choice]) -> String {
        if case .text(let value) = value { return value }
        return choices.first?.id ?? ""
    }
}

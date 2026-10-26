import SwiftUI

struct SkinParameterSettingsView: View {
    let skinID: String
    let surface: SkinSurface
    let definitions: [SkinParameterDefinition]
    let store: SkinParameterStore

    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @EnvironmentObject private var themeStore: ThemeStore

    private var visibleDefinitions: [SkinParameterDefinition] {
        definitions.filter { $0.isUserVisible && $0.surfaces.contains(surface) && isVisible($0) }
    }

    var body: some View {
        let _ = store.revision
        VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
            ForEach(sections, id: \.offset) { section in
                if let title = section.title { Text(title).settingsDescriptionStyle() }
                ForEach(section.definitions) { definition in
                    parameterRow(definition)
                }
            }
        }
    }

    /// Consecutive rows that share a `section`, in declaration order.
    private var sections: [(offset: Int, title: String?, definitions: [SkinParameterDefinition])] {
        var result: [(offset: Int, title: String?, definitions: [SkinParameterDefinition])] = []
        for definition in visibleDefinitions {
            if let last = result.indices.last, result[last].title == definition.section {
                result[last].definitions.append(definition)
            } else {
                result.append((result.count, definition.section, [definition]))
            }
        }
        return result
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
        case .color:
            ColorPicker(definition.title, selection: Binding(
                get: { SkinValue(store.value(skinID: skinID, surface: surface, definition: definition)).colorValue?.swiftUIColor ?? themeStore.accentColor },
                set: { set(definition, value: .text(OKLCHColor(NSColor($0)).hexString)) }
            )).settingsRowLabelStyle()
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

    private func isVisible(_ definition: SkinParameterDefinition) -> Bool {
        guard let condition = definition.visibleWhen else { return true }
        var environment = SkinCompileEnvironment()
        environment.params = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, SkinValue($0.defaultValue).type) })
        guard let expression = try? SkinExpressionCompiler.compile(.text(condition.hasPrefix("=") ? condition : "=" + condition), expected: .boolean, environment: environment) else { return false }
        let data = SkinSceneData()
        data.set(.params, store.values(skinID: skinID, surface: surface, definitions: definitions).mapValues(SkinValue.init))
        return expression.evaluate(.init(data: data)).isTruthy
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

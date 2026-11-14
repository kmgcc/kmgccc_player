import SwiftUI

@MainActor
@Observable
final class AudioProgramAreaChoice: Identifiable {
    let id: UUID
    let title: String
    let labels: [String]
    let trackTitles: [String]
    let actionTitle: String
    let fileName: String
    let areas: [Int]
    var selectedArea: Int
    private var completion: ((Int?) -> Void)?

    init(id: UUID = UUID(), title: String = "选择 SACD 音频区域", labels: [String] = [], trackTitles: [String] = [], actionTitle: String = "导入", fileName: String, areas: [Int], selectedArea: Int, completion: @escaping (Int?) -> Void) {
        self.id = id
        self.title = title
        self.labels = labels
        self.trackTitles = trackTitles
        self.actionTitle = actionTitle
        self.fileName = fileName
        self.areas = areas
        self.selectedArea = selectedArea
        self.completion = completion
    }
    func finish(_ area: Int?) {
        let callback = completion
        completion = nil
        callback?(area)
    }
}

struct AudioProgramAreaChoiceView: View {
    @Bindable var request: AudioProgramAreaChoice
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        SettingsTaskDialog(title: request.title, subtitle: request.fileName,
            systemImage: "opticaldisc", iconColor: themeStore.accentColor, onClose: { finish(nil) }) {
            if request.areas.count > 1 {
                Picker("导入内容", selection: $request.selectedArea) {
                    ForEach(request.areas, id: \.self) { area in
                        Text(request.labels.isEmpty ? (area == 0 ? "立体声" : "多声道") : request.labels[area]).tag(area)
                    }
                }
                .pickerStyle(.radioGroup)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !request.trackTitles.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(request.trackTitles.enumerated()), id: \.offset) { _, title in
                            Text(title).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        } footer: {
            SettingsTaskDialogButton("取消", kind: .secondary) { finish(nil) }
            SettingsTaskDialogButton(request.actionTitle, kind: .primary) { finish(request.selectedArea) }
        }
        .frame(width: 440, height: request.trackTitles.isEmpty ? 240 : 480)
        .onDisappear { request.finish(nil) }
    }
    private func finish(_ area: Int?) {
        request.finish(area)
        dismiss()
    }
}

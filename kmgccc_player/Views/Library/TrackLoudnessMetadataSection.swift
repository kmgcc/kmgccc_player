//
//  TrackLoudnessMetadataSection.swift
//  myPlayer2
//
//  Loudness measurement shown at the bottom of the detailed metadata in the
//  song and batch information editors, with a button to measure again.
//

import SwiftUI

struct TrackLoudnessMetadataSection: View {
    let trackIDs: [UUID]

    @Environment(LibraryViewModel.self) private var libraryVM
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var records: [UUID: LoudnessTrackRecord] = [:]

    var body: some View {
        if let service = libraryVM.loudnessService, !trackIDs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Text("响度")
                        .font(.subheadline)
                        .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                    Spacer(minLength: 8)
                    Button {
                        libraryVM.onRemeasureLoudness?(trackIDs)
                    } label: {
                        Label("重新测量", systemImage: "waveform")
                    }
                    .audioDSPCapsuleButtonStyle()
                    .font(.caption)
                    .disabled(isMeasuring(service))
                }

                VStack(alignment: .leading, spacing: 6) {
                    if trackIDs.count == 1, let id = trackIDs.first {
                        singleRows(service: service, trackID: id)
                    } else {
                        batchRows(service: service)
                    }
                }
                .font(.caption)
                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
            }
            .task(id: reloadKey(service)) {
                records = await service.loadRecordsSnapshot(trackIDs: trackIDs)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func singleRows(service: LibraryLoudnessService, trackID: UUID) -> some View {
        let measurement = records[trackID]?.measurement
        row("状态", stateText(service.measurementState(for: trackID)))
        row("综合响度", measurement?.integratedLUFS.map { "\(Self.number($0)) LUFS" } ?? "")
        row("真峰值", measurement?.truePeakDBTP.map { "\(Self.number($0)) dBTP" } ?? "")
        row("采样峰值", measurement?.samplePeakDBFS.map { "\(Self.number($0)) dBFS" } ?? "")
        row("测量时间", records[trackID].map { $0.analyzedAt.formatted(date: .abbreviated, time: .shortened) } ?? "")
    }

    @ViewBuilder
    private func batchRows(service: LibraryLoudnessService) -> some View {
        let progress = service.libraryProgress(trackIDs: trackIDs)
        let values = trackIDs.compactMap { records[$0]?.measurement?.integratedLUFS }
        row("已测量", "\(progress.measured.formatted()) / \(trackIDs.count.formatted()) 首")
        if progress.failed > 0 {
            row("无法测量", "\(progress.failed.formatted()) 首")
        }
        if let low = values.min(), let high = values.max() {
            row("综合响度", low == high
                ? "\(Self.number(low)) LUFS"
                : "\(Self.number(low)) 至 \(Self.number(high)) LUFS")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .frame(width: 118, alignment: .leading)
                .foregroundStyle(themeStore.appForegroundPalette.tertiaryColor)
            Text(value.isEmpty ? "未记录" : value)
                .monospacedDigit()
                .lineLimit(1)
                .textSelection(.enabled)
        }
    }

    // MARK: State

    private func stateText(_ state: LoudnessTrackMeasurementState) -> String {
        switch state {
        case .unmeasured: "未测量"
        case .waiting: "等待测量"
        case .measuring(let phase, let fraction):
            fraction.map { "\(phase.title) \(Int(($0 * 100).rounded()))%" } ?? phase.title
        case .paused: "已暂停"
        case .measured: "已测量"
        case .failed(let message): message
        }
    }

    private func isMeasuring(_ service: LibraryLoudnessService) -> Bool {
        trackIDs.contains { id in
            switch service.measurementState(for: id) {
            case .waiting(let priority): priority == .userRequested
            case .measuring: true
            default: false
            }
        }
    }

    /// Changes whenever one of the songs gets a new result, so the records
    /// shown are reloaded.
    private func reloadKey(_ service: LibraryLoudnessService) -> [Double] {
        trackIDs.map { service.index[$0]?.analyzedAt.timeIntervalSince1970 ?? 0 }
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}

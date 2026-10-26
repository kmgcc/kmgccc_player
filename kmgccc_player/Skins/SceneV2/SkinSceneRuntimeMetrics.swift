import Foundation
import SwiftUI

@MainActor
final class SkinSceneRuntimeMetrics {
    static let shared = SkinSceneRuntimeMetrics()
    struct Record { var nodes: Int; var frames: UInt64 = 0; var audioReaders: Int = 0 }
    private(set) var records: [String: Record] = [:]
    func mount(_ id: String, nodes: Int) { records[id] = Record(nodes: nodes) }
    func unmount(_ id: String) { records.removeValue(forKey: id) }
    func frame(_ id: String, audioReaders: Int) { records[id]?.frames &+= 1; records[id]?.audioReaders = audioReaders }
}

extension EnvironmentValues {
    @Entry var skinSceneMetricsID = ""
}

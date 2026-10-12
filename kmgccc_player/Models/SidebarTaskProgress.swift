//
//  SidebarTaskProgress.swift
//  myPlayer2
//
//  Lightweight presentation model for compact sidebar background-task status.
//

import Foundation

struct SidebarTaskProgress: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case running
        case completed
        case failed
        case reminder
    }

    let title: String
    let detail: String
    let fractionCompleted: Double?
    let state: State
    /// Symbol for a running task with known progress; a download arrow
    /// when nil.
    var systemImage: String? = nil

    var percentageText: String? {
        guard let fractionCompleted else { return nil }
        let bounded = min(1, max(0, fractionCompleted))
        return "\(Int((bounded * 100).rounded()))%"
    }
}

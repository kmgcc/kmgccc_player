import Combine
import Foundation
import SwiftData

@MainActor
final class ActiveLibraryBinding: ObservableObject {
    @Published private(set) var generation: UInt64 = 0
    @Published private(set) var activeSession: LibrarySession?

    let placeholderModelContainer: ModelContainer

    init(placeholderModelContainer: ModelContainer) {
        self.placeholderModelContainer = placeholderModelContainer
    }

    var context: LibraryContext? { activeSession?.context }
    var modelContainer: ModelContainer {
        activeSession?.modelContainer ?? placeholderModelContainer
    }

    func publish(_ session: LibrarySession) {
        generation &+= 1
        activeSession = session
    }

    @discardableResult
    func releaseActiveSession() -> LibrarySession? {
        generation &+= 1
        defer { activeSession = nil }
        return activeSession
    }
}

import Foundation

/// The list owns selected IDs; this value only owns how selection mode began.
nonisolated struct ListMultiselectState {
    private(set) var isActive = false
    private(set) var isManual = false
    private(set) var modifiersHeld = false

    mutating func updateModifiers(held: Bool, hasSelection: Bool, isAllowed: Bool) {
        modifiersHeld = held
        guard isAllowed else {
            clear()
            return
        }
        if held {
            isActive = true
        } else if !isManual && !hasSelection {
            isActive = false
        }
    }

    /// Clicking during temporary keyboard selection pins the mode. A later
    /// click, or any existing exit action, clears it.
    @discardableResult
    mutating func toggleManually() -> Bool {
        if isActive && (isManual || !modifiersHeld) {
            clear()
        } else {
            isManual = true
            isActive = true
        }
        return isActive
    }

    mutating func beginPersistentSelection() {
        isManual = true
        isActive = true
    }

    mutating func reconcileSelection(hasSelection: Bool) {
        if !hasSelection && !isManual && !modifiersHeld { isActive = false }
    }

    mutating func clear() {
        isActive = false
        isManual = false
        modifiersHeld = false
    }

    static func range(from anchor: UUID?, to item: UUID, in orderedIDs: [UUID]) -> Set<UUID>? {
        guard let anchor,
              let start = orderedIDs.firstIndex(of: anchor),
              let end = orderedIDs.firstIndex(of: item) else { return nil }
        return Set(orderedIDs[min(start, end)...max(start, end)])
    }
}

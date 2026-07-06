//
//  LibraryRowInput.swift
//  myPlayer2
//
//  Shared row input helpers for library lists.
//

import AppKit

enum LibraryRowInput {
    static var isShiftPressed: Bool {
        if let currentEvent = NSApp.currentEvent {
            return currentEvent.modifierFlags.contains(.shift)
        }
        return NSEvent.modifierFlags.contains(.shift)
    }
}

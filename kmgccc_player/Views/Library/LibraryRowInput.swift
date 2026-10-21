//
//  LibraryRowInput.swift
//  myPlayer2
//
//  Shared row input helpers for library lists.
//

import AppKit

enum LibraryRowInput {
    static var selectionModifiersHeld: Bool {
        !(NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).intersection([.command, .shift]).isEmpty
    }

    static var isCommandPressed: Bool {
        (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.command)
    }

    static var isShiftPressed: Bool {
        if let currentEvent = NSApp.currentEvent {
            return currentEvent.modifierFlags.contains(.shift)
        }
        return NSEvent.modifierFlags.contains(.shift)
    }
}

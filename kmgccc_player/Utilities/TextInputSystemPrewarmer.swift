//
//  TextInputSystemPrewarmer.swift
//  myPlayer2
//
//  kmgccc_player - First-use text-input cold-start front-loader.
//

import AppKit

/// Warms the macOS text-input stack once, off the user-interaction path.
///
/// The first time *any* editable text control (SwiftUI `TextField`/`TextEditor`,
/// which are AppKit-backed, or a raw `NSTextView`/`NSTextField`) becomes first
/// responder, AppKit lazily spins up the shared field editor, a Text Services
/// Manager (TSM) / input-method (IMK) session, and — if spell checking is on —
/// the `AppleSpell` XPC service. Measured cold, that first activation blocks the
/// main thread for ~150–800ms. The cost is paid by the *system services*, not by
/// the SwiftUI view, which is why prewarming an editor view alone never helped.
///
/// Because that block lands on the main thread while music plays, the UI (scrubber,
/// spectrum, lyrics) freezes for the duration and is easily misperceived as an
/// audio glitch — even though `AVAudioEngine` keeps rendering from its real-time
/// thread, unaffected by main-thread stalls. Running this warm-up once at launch
/// idle front-loads the services so the first real text edit (e.g. opening the
/// song-Info editor) is cheap, with no change to the open-to-edit interaction.
@MainActor
enum TextInputSystemPrewarmer {
    private static var didRun = false

    /// Idempotent. Builds a throwaway offscreen text surface, drives it through
    /// the first-responder + insert-text + spell-check path that triggers the
    /// lazy service spin-up, then tears it down. Never becomes key, so it cannot
    /// steal focus from the real window; the offscreen window never appears.
    static func prewarmOnce() {
        guard !didRun else { return }
        didRun = true

        let token = FirstUseHitchDiagnostics.begin("TextInputSystemPrewarm")
        defer { FirstUseHitchDiagnostics.end(token) }

        // Offscreen origin so nothing is ever visible, even for one runloop tick.
        let frame = NSRect(x: 0, y: -10_000, width: 320, height: 120)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isExcludedFromWindowsMenu = true
        window.alphaValue = 0

        let textView = NSTextView(frame: window.contentView?.bounds ?? frame)
        textView.isContinuousSpellCheckingEnabled = true
        window.contentView?.addSubview(textView)

        // orderFront (not makeKey) is enough to host a first responder while
        // leaving the app's real key window untouched.
        window.orderFront(nil)
        window.makeFirstResponder(textView)

        // insertText drives the field-editor / TSM path; the spell check spawns
        // AppleSpell. Both are the expensive first-time service activations.
        textView.insertText("warm", replacementRange: NSRange(location: 0, length: 0))
        _ = NSSpellChecker.shared.checkSpelling(of: "teh quick borwn fox", startingAt: 0)

        window.makeFirstResponder(nil)
        window.orderOut(nil)

        Log.info("[TextInputSystemPrewarm] text-input services warmed", category: .perf)
    }
}

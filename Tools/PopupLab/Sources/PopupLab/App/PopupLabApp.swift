import AppKit
import SwiftUI

@main
struct PopupLabApp: App {
    @NSApplicationDelegateAdaptor(PopupLabDelegate.self) private var delegate

    var body: some Scene {
        Window("Popup Lab", id: "popup-lab") {
            LabRootView()
        }
        .defaultSize(width: 1280, height: 850)
        .windowResizability(.contentMinSize)
    }
}

final class PopupLabDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

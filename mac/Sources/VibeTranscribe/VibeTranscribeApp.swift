import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when running as a bare SwiftPM executable (no bundle LSUIElement handling).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct VibeTranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var queue = JobQueue()

    var body: some Scene {
        WindowGroup("VibeTranscribe") {
            RootView()
                .environmentObject(queue)
                .frame(minWidth: 560, minHeight: 480)
        }
    }
}

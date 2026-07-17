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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if JobQueue.shared.hasActiveWork || RecordingController.activeSession {
            let alert = NSAlert()
            alert.messageText = RecordingController.activeSession
                ? "Recording in progress" : "Transcription in progress"
            alert.informativeText = RecordingController.activeSession
                ? "The current recording will be lost if you quit now."
                : "Files still in the queue won't be transcribed if you quit now."
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Keep Transcribing")
            if alert.runModal() != .alertFirstButtonReturn {
                return .terminateCancel
            }
        }
        // Never leave an orphaned ffmpeg/whisper child burning CPU.
        WhisperEngine.terminateActiveProcesses()
        return .terminateNow
    }
}

@main
struct StenoDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var queue = JobQueue.shared

    init() {
        // Before any view reads modelIsReady, so existing installs don't
        // re-download 466 MB under the new app identity.
        WhisperEngine.migrateLegacyModelIfNeeded()
    }

    var body: some Scene {
        WindowGroup("StenoDrop") {
            RootView()
                .environmentObject(queue)
                .frame(minWidth: 560, minHeight: 480)
        }
        Settings {
            SettingsView()
                .environmentObject(queue)
        }
    }
}

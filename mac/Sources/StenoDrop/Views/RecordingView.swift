import AppKit
import SwiftUI

struct RecordingView: View {
    @ObservedObject var recorder: RecordingController
    @EnvironmentObject var queue: JobQueue
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            header
            recordControls
            transcriptArea
            statusMessages
            footer
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 440)
        .interactiveDismissDisabled(recorder.isRecording || recorder.isFinishing)
    }

    private var header: some View {
        HStack {
            Label("Record", systemImage: "record.circle")
                .font(.headline)
            Spacer()
            Text("\(languageName)\(queue.translateToEnglish ? " → English" : "")")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .help("Language and translate settings from the main window, applied per chunk.")
        }
    }

    private var languageName: String {
        JobQueue.languages.first { $0.code == queue.languageCode }?.name ?? queue.languageCode
    }

    private var recordControls: some View {
        VStack(spacing: 8) {
            Button {
                if recorder.isRecording {
                    Task { await recorder.stop() }
                } else {
                    Task { await recorder.start() }
                }
            } label: {
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .disabled(recorder.isFinishing)
            .help(recorder.isRecording ? "Stop and save the recording." : "Start recording from the microphone.")

            Text(timeString)
                .font(.system(.title2, design: .monospaced).weight(.medium))
                .foregroundStyle(recorder.isRecording ? .primary : .secondary)

            Text(statusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var timeString: String {
        let total = Int(recorder.elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private var statusLabel: String {
        if recorder.isFinishing { return "Finishing — transcribing the last chunk…" }
        if recorder.isRecording { return "Recording — transcript updates about every 15 seconds" }
        return "Saves WAV + transcript to ~/Documents/StenoDrop"
    }

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(recorder.liveTranscript.isEmpty
                    ? "Live transcript appears here." : recorder.liveTranscript)
                    .textSelection(.enabled)
                    .foregroundStyle(recorder.liveTranscript.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .id("transcript")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: recorder.liveTranscript) { _, _ in
                withAnimation { proxy.scrollTo("transcript", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private var statusMessages: some View {
        if recorder.permissionDenied {
            HStack(spacing: 8) {
                Image(systemName: "mic.slash.fill").foregroundStyle(.red)
                Text("Microphone access is denied. Allow StenoDrop under Privacy & Security → Microphone.")
                    .font(.caption)
                Button("Open System Settings") {
                    if let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                    {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let error = recorder.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let saved = recorder.lastSavedURL {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Saved \(saved.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([saved])
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            Button(copied ? "Copied" : "Copy Transcript") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(recorder.liveTranscript, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            }
            .disabled(recorder.liveTranscript.isEmpty)
            Spacer()
            Button("Close") { dismiss() }
                .disabled(recorder.isRecording || recorder.isFinishing)
        }
    }
}

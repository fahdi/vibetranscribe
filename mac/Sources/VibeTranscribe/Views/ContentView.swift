import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var queue: JobQueue
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if queue.jobs.isEmpty {
                dropZone
            } else {
                jobList
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(6)
                    .background(Color.accentColor.opacity(0.08))
                    .allowsHitTesting(false)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            Label("VibeTranscribe", systemImage: "waveform")
                .font(.headline)
            Spacer()
            Toggle("Translate to English", isOn: $queue.translateToEnglish)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("On: any language → English. Off: transcript stays in the spoken language.")
            Button {
                chooseFolder()
            } label: {
                Label("Add Files or Folder…", systemImage: "folder.badge.plus")
            }
            if queue.hasFinishedJobs {
                Button("Clear Finished") { queue.clearFinished() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Drop audio files or folders here")
                .font(.title3.weight(.medium))
            Text("Transcripts are saved as .txt next to each file — all offline, all free.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Browse…") { chooseFolder() }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var jobList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(queue.jobs) { job in
                    JobRowView(job: job)
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Input

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Transcribe"
        panel.message = "Pick audio files, or folders to transcribe everything inside."
        if panel.runModal() == .OK {
            queue.ingest(urls: panel.urls)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            queue.ingest(urls: urls)
        }
        return true
    }
}

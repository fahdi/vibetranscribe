import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var queue: JobQueue
    @State private var isDropTargeted = false
    // Owned here (not by the sheet) so an active recording survives the
    // sheet's view identity; dismissal is blocked while recording anyway.
    @StateObject private var recorder = RecordingController()
    @State private var showRecorder = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let notice = queue.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.12))
                    .transition(.opacity)
            }
            Divider()
            if queue.jobs.isEmpty {
                dropZone
            } else {
                jobList
            }
        }
        .animation(.default, value: queue.notice)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .sheet(isPresented: $showRecorder) {
            RecordingView(recorder: recorder)
                .environmentObject(queue)
        }
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
            Label("StenoDrop", systemImage: "waveform")
                .font(.headline)
            Spacer()
            Picker("Language", selection: $queue.languageCode) {
                ForEach(JobQueue.languages, id: \.code) { language in
                    Text(language.name).tag(language.code)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Spoken language of the audio. Auto-detect works well; force it if short clips get misidentified.")
            translationMenu
            Button {
                showRecorder = true
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .help("Record from the microphone with live transcription.")
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

    /// The original spoken-language transcript is always produced
    /// (`filename.txt`); each checked language here adds one more output
    /// file (`filename.en.txt`, `filename.fr.txt`, ...).
    private var translationMenu: some View {
        Menu {
            ForEach(JobQueue.languages.filter { $0.code != "auto" }, id: \.code) { language in
                Toggle(
                    language.name,
                    isOn: Binding(
                        get: { queue.targetLanguages.contains(language.code) },
                        set: { isOn in
                            if isOn {
                                queue.targetLanguages.insert(language.code)
                            } else {
                                queue.targetLanguages.remove(language.code)
                            }
                        }
                    ))
            }
        } label: {
            Label(translationMenuTitle, systemImage: "globe")
        }
        .help(
            "Translate transcripts and caption files into one or more additional languages. "
                + "Each selected language is saved as its own file alongside the original; "
                + "caption files also get a timed .srt/.vtt track per language."
        )
    }

    private var translationMenuTitle: String {
        switch queue.targetLanguages.count {
        case 0: "Translate To…"
        case 1: "Translate To: \(languageName(queue.targetLanguages.first!))"
        default: "Translate To: \(queue.targetLanguages.count) languages"
        }
    }

    private func languageName(_ code: String) -> String {
        JobQueue.languages.first { $0.code == code }?.name ?? code
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Drop audio, video, or caption files (.srt/.vtt) here")
                .font(.title3.weight(.medium))
            Text(
                "Transcripts are saved as .txt and captions as cleaned, translated "
                    + ".srt/.vtt next to each file — all offline, all free.")
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
        panel.prompt = "Add"
        panel.message =
            "Pick audio files or .srt/.vtt caption files, or folders to process everything inside."
        if panel.runModal() == .OK {
            queue.ingest(urls: panel.urls)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        // Indexed slots: provider completions land on background threads in
        // arbitrary order, but the queue should preserve the drag order.
        var slots = [URL?](repeating: nil, count: providers.count)
        let lock = NSLock()

        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    slots[index] = url
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            queue.ingest(urls: slots.compactMap { $0 })
        }
        return true
    }
}

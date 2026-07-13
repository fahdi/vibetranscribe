import Foundation

@MainActor
final class JobQueue: ObservableObject {
    @Published var jobs: [TranscriptionJob] = []
    @Published var translateToEnglish = true

    private var isProcessing = false

    static let audioExtensions: Set<String> = [
        "wav", "mp3", "m4a", "aac", "flac", "ogg", "oga", "opus",
        "aiff", "aif", "caf", "amr", "wma", "mp4", "mov", "m4v", "webm", "mkv",
    ]

    var hasFinishedJobs: Bool { jobs.contains { $0.status.isFinished } }

    // MARK: - Ingest

    func ingest(urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                continue
            }
            if isDir.boolValue {
                files.append(contentsOf: audioFiles(in: url))
            } else if Self.audioExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }

        let pendingPaths = Set(
            jobs.filter { !$0.status.isFinished }.map { $0.sourceURL.path })
        var seen = pendingPaths
        for file in files {
            let path = file.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            jobs.append(TranscriptionJob(sourceURL: file.standardizedFileURL))
        }
        pump()
    }

    private func audioFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var found: [URL] = []
        for case let url as URL in enumerator
        where Self.audioExtensions.contains(url.pathExtension.lowercased()) {
            found.append(url)
        }
        return found.sorted { $0.path < $1.path }
    }

    func clearFinished() {
        jobs.removeAll { $0.status.isFinished }
    }

    // MARK: - Processing

    private func pump() {
        guard !isProcessing else { return }
        guard let index = jobs.firstIndex(where: { $0.status == .queued }) else { return }
        isProcessing = true

        let job = jobs[index]
        let translate = translateToEnglish
        // Conversion is sub-second; whisper dominates, so show one active state.
        jobs[index].status = .transcribing

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                () -> Result<String, Error> in
                do {
                    return .success(
                        try WhisperEngine.transcribe(job.sourceURL, translateToEnglish: translate))
                } catch {
                    return .failure(error)
                }
            }.value

            if let idx = self.jobs.firstIndex(where: { $0.id == job.id }) {
                switch result {
                case .success(let text):
                    self.jobs[idx].transcript = text
                    do {
                        try text.write(to: job.outputURL, atomically: true, encoding: .utf8)
                        self.jobs[idx].status = .done
                    } catch {
                        self.jobs[idx].status = .doneWithWarning(
                            "Couldn't save \(job.outputURL.lastPathComponent): \(error.localizedDescription)")
                    }
                case .failure(let error):
                    self.jobs[idx].status = .failed(error.localizedDescription)
                }
            }
            self.isProcessing = false
            self.pump()
        }
    }
}

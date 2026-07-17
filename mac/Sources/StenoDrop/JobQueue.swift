import Foundation

@MainActor
final class JobQueue: ObservableObject {
    static let shared = JobQueue()

    /// Whisper language options: (ISO-639-1 code, display name).
    /// "auto" lets Whisper detect; forcing a language avoids misdetection
    /// on short clips (e.g. Urdu heard as Hindi).
    static let languages: [(code: String, name: String)] = [
        ("auto", "Auto-detect"),
        ("ur", "Urdu"),
        ("en", "English"),
        ("ar", "Arabic"),
        ("bn", "Bengali"),
        ("zh", "Chinese"),
        ("fr", "French"),
        ("de", "German"),
        ("hi", "Hindi"),
        ("id", "Indonesian"),
        ("it", "Italian"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("fa", "Persian"),
        ("pt", "Portuguese"),
        ("pa", "Punjabi"),
        ("ps", "Pashto"),
        ("ru", "Russian"),
        ("es", "Spanish"),
        ("tr", "Turkish"),
    ]

    @Published var jobs: [TranscriptionJob] = []
    /// Languages the transcript is additionally translated into, beyond the
    /// original spoken language (which is always produced). "en" uses
    /// whisper's own native translate task; any other code routes through
    /// `TranslationBridge`. See `TranslationPipeline`.
    @Published var targetLanguages: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(targetLanguages), forKey: "targetLanguages")
        }
    }
    @Published var languageCode: String {
        didSet { UserDefaults.standard.set(languageCode, forKey: "languageCode") }
    }
    @Published var notice: String?

    init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.stringArray(forKey: "targetLanguages") {
            targetLanguages = Set(saved)
        } else {
            // Pre-multi-language installs only had a translateToEnglish
            // bool (default true) — carry that choice forward once.
            let legacyTranslate = defaults.object(forKey: "translateToEnglish") as? Bool ?? true
            targetLanguages = legacyTranslate ? ["en"] : []
        }
        let saved = defaults.string(forKey: "languageCode") ?? "auto"
        languageCode =
            Self.languages.contains { $0.code == saved } ? saved : "auto"
    }

    /// Live-recording chunks (see `RecordingController`) only support the
    /// existing English-only translate path — multi-language translation
    /// per ~15 s chunk would be too heavy for real-time use. Scoped to the
    /// batch file pipeline only for now.
    var translatesToEnglish: Bool { targetLanguages.contains("en") }

    private var isProcessing = false
    private var noticeClearTask: Task<Void, Never>?

    static let audioExtensions: Set<String> = [
        "wav", "mp3", "m4a", "m4b", "aac", "flac", "ogg", "oga", "opus",
        "aiff", "aif", "caf", "amr", "wma", "3gp",
        "mp4", "mov", "m4v", "avi", "webm", "mkv",
    ]

    var hasFinishedJobs: Bool { jobs.contains { $0.status.isFinished } }
    var hasActiveWork: Bool {
        jobs.contains { $0.status == .queued || $0.status.isActive }
    }

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
        var added = 0
        for file in files {
            let source = file.standardizedFileURL
            guard !seen.contains(source.path) else { continue }
            seen.insert(source.path)
            jobs.append(
                TranscriptionJob(sourceURL: source, outputURL: outputURL(for: source)))
            added += 1
        }

        if added == 0, !urls.isEmpty {
            showNotice("No supported audio files in that drop.")
        }
        pump()
    }

    /// `song.txt`, unless another queued source (e.g. song.wav vs song.mp3)
    /// already claims it — then `song.mp3.txt`.
    private func outputURL(for source: URL) -> URL {
        let claimed = Set(
            jobs.filter { $0.sourceURL.path != source.path }.map { $0.outputURL.path })
        let primary = source.deletingPathExtension().appendingPathExtension("txt")
        if !claimed.contains(primary.path) { return primary }
        return source.appendingPathExtension("txt")
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeClearTask?.cancel()
        noticeClearTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { self.notice = nil }
        }
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
        let languages = targetLanguages
        let language = languageCode
        // Conversion is sub-second; whisper dominates, so show one active state.
        jobs[index].status = .transcribing

        Task {
            // The original-language transcript is always produced first —
            // every additional target language translates from this, either
            // via whisper re-run (English) or TranslationBridge (others).
            let originalResult = await Task.detached(priority: .userInitiated) {
                () -> Result<String, Error> in
                do {
                    return .success(
                        try WhisperEngine.transcribe(
                            job.sourceURL, translateToEnglish: false, language: language))
                } catch {
                    return .failure(error)
                }
            }.value

            guard let idx = self.jobs.firstIndex(where: { $0.id == job.id }) else {
                self.isProcessing = false
                self.pump()
                return
            }

            switch originalResult {
            case .failure(let error):
                self.jobs[idx].status = .failed(error.localizedDescription)
            case .success(let originalText):
                self.jobs[idx].transcript = originalText
                var warnings: [String] = []

                do {
                    try originalText.write(
                        to: job.outputURL(forLanguage: nil), atomically: true, encoding: .utf8)
                } catch {
                    warnings.append(
                        "Couldn't save \(job.outputURL.lastPathComponent): \(error.localizedDescription)")
                }

                let outcomes = await TranslationPipeline.run(
                    originalText: originalText,
                    targetLanguages: languages,
                    whisperTranslate: {
                        try await Task.detached(priority: .userInitiated) {
                            try WhisperEngine.transcribe(
                                job.sourceURL, translateToEnglish: true, language: language)
                        }.value
                    },
                    engine: TranslationBridge.shared
                )

                for outcome in outcomes {
                    let dest = job.outputURL(forLanguage: outcome.language)
                    switch outcome.result {
                    case .success(let text):
                        do {
                            try text.write(to: dest, atomically: true, encoding: .utf8)
                        } catch {
                            warnings.append(
                                "Couldn't save \(dest.lastPathComponent): \(error.localizedDescription)")
                        }
                    case .failure(let error):
                        warnings.append(
                            "\(outcome.language.uppercased()) translation failed: \(error.localizedDescription)")
                    }
                }

                self.jobs[idx].status =
                    warnings.isEmpty ? .done : .doneWithWarning(warnings.joined(separator: "; "))
            }

            self.isProcessing = false
            self.pump()
        }
    }
}

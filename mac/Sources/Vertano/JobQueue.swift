import Foundation
import NaturalLanguage

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

    @Published var jobs: [Job] = []
    /// Languages the transcript is additionally translated into, beyond the
    /// original spoken language (which is always produced). For audio, "en"
    /// uses whisper's own native translate task; any other code routes
    /// through `TranslationBridge`. Caption jobs send every target —
    /// including "en" — through the bridge (there is no audio to re-run).
    @Published var targetLanguages: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(targetLanguages), forKey: "targetLanguages")
        }
    }
    @Published var languageCode: String {
        didSet { UserDefaults.standard.set(languageCode, forKey: "languageCode") }
    }
    @Published var notice: String?

    /// Tests flip this off so `ingest` can be exercised without spawning
    /// whisper subprocesses or wedging on a real translation session.
    var startsProcessingAutomatically = true

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

    static let captionExtensions: Set<String> = ["srt", "vtt"]

    var hasFinishedJobs: Bool { jobs.contains { $0.status.isFinished } }
    var hasActiveWork: Bool {
        jobs.contains { $0.status == .queued || $0.status.isActive }
    }

    // MARK: - Ingest

    func ingest(urls: [URL]) {
        var audio: [URL] = []
        var captions: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                continue
            }
            if isDir.boolValue {
                let found = supportedFiles(in: url)
                audio.append(contentsOf: found.audio)
                captions.append(contentsOf: found.captions)
            } else if Self.audioExtensions.contains(url.pathExtension.lowercased()) {
                audio.append(url)
            } else if Self.captionExtensions.contains(url.pathExtension.lowercased()) {
                captions.append(url)
            }
        }

        let partition = Self.preferringCaptions(audio: audio, captions: captions)

        let pendingPaths = Set(
            jobs.filter { !$0.status.isFinished }.map { $0.sourceURL.path })
        var seen = pendingPaths
        var added = 0
        for file in partition.audio {
            let source = file.standardizedFileURL
            guard seen.insert(source.path).inserted else { continue }
            jobs.append(
                .audio(
                    TranscriptionJob(
                        sourceURL: source,
                        outputURL: audioOutputURL(for: source),
                        targetLanguageCodes: targetLanguages)))
            added += 1
        }
        for file in captions {
            let source = file.standardizedFileURL
            guard seen.insert(source.path).inserted,
                let format = CaptionFormat(fileExtension: source.pathExtension)
            else { continue }
            jobs.append(
                .captions(
                    CaptionJob(
                        sourceURL: source,
                        format: format,
                        targetOutputs: claimTargetOutputs(source: source, format: format))))
            added += 1
        }

        if added == 0, !urls.isEmpty {
            showNotice("No supported audio, video, or caption files in that drop.")
        } else if !partition.skippedAudio.isEmpty {
            let names = partition.skippedAudio.map(\.lastPathComponent).joined(separator: ", ")
            showNotice("Using the caption file instead of the media for: \(names)")
        }
        pump()
    }

    /// Mixed-folder rule (§8): when a drop contains both a media file and a
    /// caption file for the same content, the caption file wins — captions
    /// are compared on STRIPPED basenames because yt-dlp always writes
    /// `<name>.<lang>.<ext>` (`Talk.mp4` matches `Talk.en.vtt`, not
    /// `Talk.part2.vtt`).
    static func preferringCaptions(
        audio: [URL], captions: [URL]
    ) -> (audio: [URL], skippedAudio: [URL]) {
        func key(_ url: URL) -> String {
            url.deletingLastPathComponent().path + "/" + CaptionNaming.strippedBaseName(url)
        }
        let captionKeys = Set(captions.map(key))
        var kept: [URL] = []
        var skipped: [URL] = []
        for url in audio {
            if captionKeys.contains(key(url)) {
                skipped.append(url)
            } else {
                kept.append(url)
            }
        }
        return (kept, skipped)
    }

    // MARK: - Output claiming (§8)

    /// Union of every queued job's source and full prospective output set —
    /// the collision check covers per-language outputs, not just the base
    /// transcript path.
    private func claimedPaths(excludingJob id: UUID? = nil) -> Set<String> {
        var paths: Set<String> = []
        for job in jobs where job.id != id {
            paths.insert(job.sourceURL.path)
            paths.formUnion(job.prospectiveOutputPaths)
        }
        return paths
    }

    /// `song.txt` (plus its per-language variants), unless another queued
    /// job's source or outputs already claim any of them — then
    /// `song.mp3.txt`.
    private func audioOutputURL(for source: URL) -> URL {
        let claimed = claimedPaths()
        func collides(_ base: URL) -> Bool {
            let probe = TranscriptionJob(
                sourceURL: source, outputURL: base, targetLanguageCodes: targetLanguages)
            return probe.prospectiveOutputPaths.contains { claimed.contains($0) }
        }
        let primary = source.deletingPathExtension().appendingPathExtension("txt")
        if !collides(primary) { return primary }
        return source.appendingPathExtension("txt")
    }

    /// Phase one: target-language paths are known at enqueue and claimed
    /// immediately. Deterministic names are app-owned and overwritten on
    /// re-run; only collisions with other queued jobs (or this job's own
    /// source file) force the fallback name.
    private func claimTargetOutputs(source: URL, format: CaptionFormat) -> [String: URL] {
        var claimed = claimedPaths()
        claimed.insert(source.path)
        let ext = CaptionNaming.containerExtension(format)
        var outputs: [String: URL] = [:]
        for code in targetLanguages.sorted() {
            let primary = CaptionNaming.outputURL(
                source: source, language: code, fileExtension: ext)
            let url =
                claimed.contains(primary.path)
                ? CaptionNaming.fallbackOutputURL(source: source, language: code, fileExtension: ext)
                : primary
            claimed.insert(url.path)
            outputs[code] = url
        }
        return outputs
    }

    /// Phase two: the source-track path depends on the resolved source
    /// language, so it is claimed mid-job under the same collision rules
    /// (never the original file itself) and surfaced in the job row.
    func claimSourceTrackURLs(jobID: UUID, languageCode: String) -> (track: URL, text: URL) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
            case .captions(var job) = jobs[index]
        else {
            let fallback = FileManager.default.temporaryDirectory
                .appendingPathComponent("stenodrop-\(languageCode)")
            return (fallback.appendingPathExtension("vtt"), fallback.appendingPathExtension("txt"))
        }
        var claimed = claimedPaths(excludingJob: jobID)
        claimed.insert(job.sourceURL.path)
        let ext = CaptionNaming.containerExtension(job.format)
        var track = CaptionNaming.outputURL(
            source: job.sourceURL, language: languageCode, fileExtension: ext)
        if claimed.contains(track.path) {
            track = CaptionNaming.fallbackOutputURL(
                source: job.sourceURL, language: languageCode, fileExtension: ext)
        }
        claimed.insert(track.path)
        var text = CaptionNaming.outputURL(
            source: job.sourceURL, language: languageCode, fileExtension: "txt")
        if claimed.contains(text.path) {
            text = CaptionNaming.fallbackOutputURL(
                source: job.sourceURL, language: languageCode, fileExtension: "txt")
        }
        job.sourceTrackURL = track
        job.sourceTextURL = text
        jobs[index] = .captions(job)
        return (track, text)
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeClearTask?.cancel()
        noticeClearTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { self.notice = nil }
        }
    }

    private func supportedFiles(in directory: URL) -> (audio: [URL], captions: [URL]) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return ([], []) }

        var audio: [URL] = []
        var captions: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if Self.audioExtensions.contains(ext) {
                audio.append(url)
            } else if Self.captionExtensions.contains(ext) {
                captions.append(url)
            }
        }
        return (
            audio.sorted { $0.path < $1.path },
            captions.sorted { $0.path < $1.path }
        )
    }

    func clearFinished() {
        jobs.removeAll { $0.status.isFinished }
    }

    // MARK: - Processing

    private func pump() {
        guard startsProcessingAutomatically, !isProcessing else { return }
        guard let index = jobs.firstIndex(where: { $0.status == .queued }) else { return }
        isProcessing = true
        switch jobs[index] {
        case .audio(let job):
            processAudio(job, at: index)
        case .captions(let job):
            processCaptions(job, at: index)
        }
    }

    private func finishCurrentJob() {
        isProcessing = false
        pump()
    }

    private func withCaptionJob(_ id: UUID, _ mutate: (inout CaptionJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
            case .captions(var job) = jobs[index]
        else { return }
        mutate(&job)
        jobs[index] = .captions(job)
    }

    private func withAudioJob(_ id: UUID, _ mutate: (inout TranscriptionJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
            case .audio(var job) = jobs[index]
        else { return }
        mutate(&job)
        jobs[index] = .audio(job)
    }

    // MARK: - Audio jobs

    private func processAudio(_ job: TranscriptionJob, at index: Int) {
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

            guard self.jobs.contains(where: { $0.id == job.id }) else {
                self.finishCurrentJob()
                return
            }

            switch originalResult {
            case .failure(let error):
                self.withAudioJob(job.id) { $0.status = .failed(error.localizedDescription) }
            case .success(let originalText):
                self.withAudioJob(job.id) { $0.transcript = originalText }
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
                    targetLanguages: job.targetLanguageCodes,
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

                self.withAudioJob(job.id) {
                    $0.status =
                        warnings.isEmpty
                        ? .done : .doneWithWarning(warnings.joined(separator: "; "))
                }
            }

            self.finishCurrentJob()
        }
    }

    // MARK: - Caption jobs

    private func processCaptions(_ job: CaptionJob, at index: Int) {
        let picker = languageCode
        jobs[index].status = .transcribing
        let jobID = job.id

        Task {
            // Parsing and reflow run off the main actor — multi-MB folder
            // drops must not beachball ingest. The recognizer is created
            // locally inside the detached task (NLLanguageRecognizer is not
            // Sendable).
            let outcome = await Task.detached(priority: .userInitiated) {
                await CaptionPipeline.run(
                    sourceURL: job.sourceURL,
                    format: job.format,
                    pickerLanguage: picker,
                    targetOutputs: job.targetOutputs,
                    engine: TranslationBridge.shared,
                    availability: AppleCaptionAvailability(),
                    detectLanguage: { text in
                        let recognizer = NLLanguageRecognizer()
                        recognizer.processString(String(text.prefix(4096)))
                        guard let dominant = recognizer.dominantLanguage else { return nil }
                        return Locale.Language(identifier: dominant.rawValue)
                    },
                    claimSourceTrack: { code in
                        await self.claimSourceTrackURLs(jobID: jobID, languageCode: code)
                    },
                    onStatus: { status in
                        await MainActor.run {
                            self.withCaptionJob(jobID) { $0.status = status }
                        }
                    }
                )
            }.value

            self.withCaptionJob(jobID) { updated in
                updated.reflowedText = outcome.reflowedText
                updated.sourceLanguageCode = outcome.sourceLanguageCode
                if let failure = outcome.failureMessage {
                    updated.status = .failed(failure)
                } else {
                    updated.status =
                        outcome.warnings.isEmpty
                        ? .done : .doneWithWarning(outcome.warnings.joined(separator: "; "))
                }
            }
            if let failure = outcome.failureMessage {
                self.showNotice(failure)
            }
            self.finishCurrentJob()
        }
    }
}

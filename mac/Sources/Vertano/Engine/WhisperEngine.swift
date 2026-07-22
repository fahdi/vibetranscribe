import Foundation

enum EngineError: LocalizedError {
    case whisperNotFound
    case ffmpegNotFound
    case modelMissing
    case conversionFailed(String)
    case transcriptionFailed(String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .whisperNotFound:
            return "whisper-cli not found. Install with: brew install whisper-cpp"
        case .ffmpegNotFound:
            return "ffmpeg not found. Install with: brew install ffmpeg"
        case .modelMissing:
            return "Whisper model not downloaded yet."
        case .conversionFailed(let detail):
            return "Audio conversion failed: \(detail)"
        case .transcriptionFailed(let detail):
            return "Transcription failed: \(detail)"
        case .emptyOutput:
            return "Transcription produced no text."
        }
    }
}

struct WhisperEngine: Sendable {
    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StenoDrop/models", isDirectory: true)
    }

    /// The tier used for transcription, persisted across launches. Absent
    /// on fresh installs and on every pre-tier install (where it resolves
    /// to `.efficient`, whose filename is the same `ggml-small.bin` those
    /// installs already have — no forced re-download).
    static var activeTier: ModelTier {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "modelTier"),
                let tier = ModelTier(rawValue: raw)
            else { return .default }
            return tier
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "modelTier") }
    }

    static func modelPath(for tier: ModelTier) -> URL {
        modelsDirectory.appendingPathComponent(tier.filename)
    }

    static var modelPath: URL { modelPath(for: activeTier) }

    /// One-time migration from the app's pre-rename identity, so existing
    /// installs don't re-download 466 MB.
    static func migrateLegacyModelIfNeeded() {
        let fm = FileManager.default
        let legacy = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeTranscribe/models/ggml-small.bin")
        let destination = modelPath(for: .efficient)
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: destination.path)
        else { return }
        try? fm.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try? fm.moveItem(at: legacy, to: destination)
    }

    static func modelIsReady(for tier: ModelTier) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: modelPath(for: tier).path)
        let size = (attrs?[.size] as? Int64) ?? 0
        return size > tier.minimumValidSize
    }

    static var modelIsReady: Bool { modelIsReady(for: activeTier) }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var binaryCache: [String: String] = [:]

    /// Pure filesystem lookup (no subprocess) so it is safe to call from the
    /// main thread. Hits are cached; misses are not, so "Check Again" works
    /// after the user installs a dependency.
    static func findBinary(_ name: String) -> String? {
        cacheLock.lock()
        let cached = binaryCache[name]
        cacheLock.unlock()
        if let cached { return cached }

        var candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/homebrew/opt/whisper-cpp/bin/\(name)",
        ]
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates += envPath.split(separator: ":").map { "\($0)/\(name)" }

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            cacheLock.lock()
            binaryCache[name] = path
            cacheLock.unlock()
            return path
        }
        return nil
    }

    static var whisperPath: String? { findBinary("whisper-cli") }
    static var ffmpegPath: String? { findBinary("ffmpeg") }

    /// Convert any audio/video input to 16 kHz mono PCM WAV, then transcribe it.
    /// `language` is a Whisper ISO-639-1 code, or "auto" to detect.
    /// Blocking; call off the main thread.
    static func transcribe(
        _ source: URL, translateToEnglish: Bool, language: String = "auto"
    ) throws -> String {
        guard let whisper = whisperPath else { throw EngineError.whisperNotFound }
        guard let ffmpeg = ffmpegPath else { throw EngineError.ffmpegNotFound }
        guard modelIsReady else { throw EngineError.modelMissing }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stenodrop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let wav = workDir.appendingPathComponent("audio.wav")
        let convert = try run(ffmpeg, [
            "-y", "-hide_banner", "-loglevel", "error", "-nostdin",
            "-i", source.path,
            "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
            wav.path,
        ])
        guard convert.exitCode == 0 else {
            throw EngineError.conversionFailed(tail(convert.stderr))
        }

        let outBase = workDir.appendingPathComponent("transcript")
        let text = try runWhisper(
            whisper, wav: wav, outBase: outBase,
            language: language, translateToEnglish: translateToEnglish)

        // Devanagari guard: auto-detect occasionally mistakes spoken Urdu for
        // Hindi and transliterates into Devanagari script. Re-run once with
        // the language forced to Urdu rather than surface the wrong script.
        if language == "auto", !translateToEnglish, TextScript.isMajorityDevanagari(text) {
            let retryBase = workDir.appendingPathComponent("transcript-ur-retry")
            if let retried = try? runWhisper(
                whisper, wav: wav, outBase: retryBase,
                language: "ur", translateToEnglish: translateToEnglish),
                !retried.isEmpty
            {
                return retried
            }
        }

        return text
    }

    /// Runs whisper-cli once against `wav` and returns the trimmed transcript.
    /// Throws `.transcriptionFailed` / `.emptyOutput` on failure.
    private static func runWhisper(
        _ whisper: String, wav: URL, outBase: URL,
        language: String, translateToEnglish: Bool
    ) throws -> String {
        var args = [
            "-m", modelPath.path,
            "-f", wav.path,
            "-l", language,
            "-otxt", "-of", outBase.path,
            "-np",
        ]
        if translateToEnglish { args.append("--translate") }

        let result = try run(whisper, args)
        guard result.exitCode == 0 else {
            throw EngineError.transcriptionFailed(tail(result.stderr))
        }

        let txtURL = outBase.appendingPathExtension("txt")
        guard let text = try? String(contentsOf: txtURL, encoding: .utf8) else {
            throw EngineError.emptyOutput
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EngineError.emptyOutput }
        return trimmed
    }

    // MARK: - Process plumbing

    struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static let processLock = NSLock()
    nonisolated(unsafe) private static var activeProcesses: [Process] = []

    /// Kill any in-flight ffmpeg/whisper child so quitting the app never
    /// leaves an orphan burning CPU.
    static func terminateActiveProcesses() {
        processLock.lock()
        let running = activeProcesses
        processLock.unlock()
        for p in running where p.isRunning { p.terminate() }
    }

    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // Read each pipe to EOF on its own background thread: the continuous
        // drain means the child can never block on a full pipe buffer, and
        // each Data is touched by exactly one thread until group.wait()
        // establishes the happens-before edge back to this one.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        do {
            try process.run()
        } catch {
            // Child never spawned: close the write ends so the readers see EOF
            // instead of hanging forever.
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            group.wait()
            throw error
        }

        processLock.lock()
        activeProcesses.append(process)
        processLock.unlock()

        process.waitUntilExit()
        group.wait()

        processLock.lock()
        activeProcesses.removeAll { $0 === process }
        processLock.unlock()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    private static func tail(_ text: String, lines: Int = 3) -> String {
        let all = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        return all.suffix(lines).joined(separator: " · ")
    }
}

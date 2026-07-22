import AVFoundation
import Foundation

enum RecordingError: LocalizedError {
    case noInputDevice
    case converterUnavailable
    case bufferAllocationFailed

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No microphone input available. Connect a mic and try again."
        case .converterUnavailable:
            return "Couldn't set up audio conversion for the microphone format."
        case .bufferAllocationFailed:
            return "Couldn't allocate audio buffers for recording."
        }
    }
}

@MainActor
final class RecordingController: ObservableObject {
    /// Read by AppDelegate's quit guard — a live mic session must not be
    /// silently killed by closing the window.
    static private(set) var activeSession = false

    @Published var isRecording = false {
        didSet { Self.activeSession = isRecording || isFinishing }
    }
    /// True between Stop and the recording landing on disk (final chunk may
    /// still be transcribing).
    @Published var isFinishing = false {
        didSet { Self.activeSession = isRecording || isFinishing }
    }
    @Published var elapsed: TimeInterval = 0
    @Published var liveTranscript = ""
    @Published var errorMessage: String?
    @Published var permissionDenied = false
    @Published var lastSavedURL: URL?
    /// Non-nil whenever a chunk is somewhere in the whisper pipeline (queued
    /// or actively transcribing), so the UI never reads as stalled during the
    /// ~15 s per-chunk turnaround. Includes a pending-chunk count once more
    /// than one is backed up.
    @Published var transcriptionStatus: String?

    /// Whisper's native input rate; everything is captured straight to this.
    nonisolated static let sampleRate = 16_000.0
    /// ~15 s of 16 kHz mono audio per live-transcription chunk.
    nonisolated private static let chunkSampleCount = 240_000
    /// whisper-cli rejects clips shorter than ~1 s; pad the final remainder
    /// with silence up to ~1.05 s.
    nonisolated private static let minimumWhisperSamples = 16_800
    /// A trailing remainder under ~0.2 s can't hold speech — skip it.
    nonisolated private static let negligibleSamples = 3_200

    private var engine: AVAudioEngine?
    private var sink: CaptureSink?
    private var tickTask: Task<Void, Never>?
    /// Chunks transcribe strictly one at a time: each new task awaits the
    /// previous one, so the recorder never runs two whisper processes at once.
    private var chunkChain: Task<Void, Never>?
    /// Count of chunks enqueued but not yet finished transcribing (including
    /// the one currently in flight). Backs `transcriptionStatus`.
    private var pendingChunkCount = 0
    private var startedAt = Date()
    private var sessionWavURL: URL?

    // MARK: - Start

    func start() async {
        guard !isRecording, !isFinishing else { return }
        errorMessage = nil
        permissionDenied = false
        lastSavedURL = nil
        liveTranscript = ""
        elapsed = 0
        pendingChunkCount = 0
        transcriptionStatus = nil

        guard await Self.requestMicrophoneAccess() else {
            permissionDenied = true
            return
        }

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stenodrop-rec-\(UUID().uuidString).wav")
        let engine = AVAudioEngine()
        do {
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw RecordingError.noInputDevice
            }
            let sink = try CaptureSink(sessionWavURL: wavURL, inputFormat: inputFormat)
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                sink.process(buffer)
            }
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.sink = sink
            self.sessionWavURL = wavURL
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            try? FileManager.default.removeItem(at: wavURL)
            errorMessage = error.localizedDescription
            return
        }

        startedAt = Date()
        isRecording = true
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.isRecording else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt)
                if let sink = self.sink, sink.pendingSampleCount >= Self.chunkSampleCount {
                    self.enqueueChunk(sink.drainPendingSamples())
                }
                if let captureError = self.sink?.takeCaptureError() {
                    self.errorMessage = captureError
                }
            }
        }
    }

    // MARK: - Stop

    /// Stops capture, flushes and transcribes the remaining audio, then moves
    /// the full-session WAV (plus a matching .txt transcript) into
    /// `destinationFolder` — default `~/Documents/StenoDrop/`.
    func stop(saveTo destinationFolder: URL? = nil) async {
        guard isRecording else { return }
        isFinishing = true
        tickTask?.cancel()
        tickTask = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRecording = false
        elapsed = Date().timeIntervalSince(startedAt)

        if let sink {
            if let captureError = sink.takeCaptureError() {
                errorMessage = captureError
            }
            var remainder = sink.drainPendingSamples()
            if remainder.count >= Self.negligibleSamples {
                if remainder.count < Self.minimumWhisperSamples {
                    remainder.append(contentsOf: [Int16](
                        repeating: 0, count: Self.minimumWhisperSamples - remainder.count))
                }
                enqueueChunk(remainder)
            }
            // Releases the AVAudioFile so the WAV header is finalized before
            // the move below.
            sink.finishSession()
        }
        sink = nil

        await chunkChain?.value
        chunkChain = nil

        saveSession(to: destinationFolder)
        isFinishing = false
    }

    private func saveSession(to destinationFolder: URL?) {
        guard let sessionWavURL else { return }
        self.sessionWavURL = nil

        let folder = destinationFolder
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("StenoDrop", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let base = "Recording \(formatter.string(from: Date()))"
            let wavDest = folder.appendingPathComponent(base + ".wav")
            let txtDest = folder.appendingPathComponent(base + ".txt")
            try FileManager.default.moveItem(at: sessionWavURL, to: wavDest)
            try liveTranscript.write(to: txtDest, atomically: true, encoding: .utf8)
            lastSavedURL = wavDest
        } catch {
            errorMessage = "Couldn't save recording: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: sessionWavURL)
        }
    }

    // MARK: - Chunk transcription

    private func enqueueChunk(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        // Settings are read at chunk time, so mid-recording toggle changes
        // apply from the next chunk onward.
        let translate = JobQueue.shared.translatesToEnglish
        let language = JobQueue.shared.languageCode
        pendingChunkCount += 1
        updateTranscriptionStatus()
        let previous = chunkChain
        chunkChain = Task {
            await previous?.value
            let result = await Task.detached(priority: .userInitiated) {
                Self.transcribeChunk(
                    samples, translateToEnglish: translate, language: language)
            }.value
            switch result {
            case .success(let text):
                if !text.isEmpty {
                    self.liveTranscript = self.liveTranscript.isEmpty
                        ? text : self.liveTranscript + " " + text
                }
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
            self.pendingChunkCount -= 1
            self.updateTranscriptionStatus()
        }
    }

    /// Refreshes `transcriptionStatus` from `pendingChunkCount`: nil when
    /// idle, otherwise "Transcribing…" with a pending-chunk suffix once more
    /// than one chunk is backed up in the pipeline.
    private func updateTranscriptionStatus() {
        guard pendingChunkCount > 0 else {
            transcriptionStatus = nil
            return
        }
        transcriptionStatus = pendingChunkCount > 1
            ? "Transcribing… (\(pendingChunkCount) chunks pending)"
            : "Transcribing…"
    }

    /// Blocking; call off the main actor. Mirrors WhisperEngine.transcribe,
    /// minus the ffmpeg step — the chunk is already 16 kHz mono pcm_s16le.
    nonisolated private static func transcribeChunk(
        _ samples: [Int16], translateToEnglish: Bool, language: String
    ) -> Result<String, Error> {
        do {
            guard let whisper = WhisperEngine.whisperPath else {
                throw EngineError.whisperNotFound
            }
            guard WhisperEngine.modelIsReady else { throw EngineError.modelMissing }

            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("stenodrop-chunk-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: workDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workDir) }

            let wav = workDir.appendingPathComponent("chunk.wav")
            try writeWav(samples, to: wav)

            let outBase = workDir.appendingPathComponent("transcript")
            var trimmed = try runWhisperChunk(
                whisper, wav: wav, outBase: outBase,
                language: language, translateToEnglish: translateToEnglish)

            // Devanagari guard: auto-detect occasionally mistakes spoken Urdu
            // for Hindi and transliterates into Devanagari script. Re-run
            // once with the language forced to Urdu rather than surface the
            // wrong script.
            if language == "auto", !translateToEnglish, TextScript.isMajorityDevanagari(trimmed) {
                let retryBase = workDir.appendingPathComponent("transcript-ur-retry")
                if let retried = try? runWhisperChunk(
                    whisper, wav: wav, outBase: retryBase,
                    language: "ur", translateToEnglish: translateToEnglish)
                {
                    trimmed = retried
                }
            }

            return .success(trimmed)
        } catch {
            return .failure(error)
        }
    }

    /// Runs whisper-cli once against `wav` and returns the trimmed transcript
    /// (silence markers stripped). Empty results are returned as "", not
    /// thrown — a silent chunk is normal mid-pause, not an error.
    nonisolated private static func runWhisperChunk(
        _ whisper: String, wav: URL, outBase: URL,
        language: String, translateToEnglish: Bool
    ) throws -> String {
        var args = [
            "-m", WhisperEngine.modelPath.path,
            "-f", wav.path,
            "-l", language,
            "-otxt", "-of", outBase.path,
            "-np",
        ]
        if translateToEnglish { args.append("--translate") }

        let result = try WhisperEngine.run(whisper, args)
        guard result.exitCode == 0 else {
            let detail = result.stderr
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .last { !$0.isEmpty } ?? "exit \(result.exitCode)"
            throw EngineError.transcriptionFailed(detail)
        }

        let txtURL = outBase.appendingPathExtension("txt")
        let text = (try? String(contentsOf: txtURL, encoding: .utf8)) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Shared audio-file helpers

    nonisolated static func makeWavFile(at url: URL) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        return try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatInt16, interleaved: true)
    }

    nonisolated private static func writeWav(_ samples: [Int16], to url: URL) throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                channels: 1, interleaved: true),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.int16ChannelData?[0]
        else { throw RecordingError.bufferAllocationFailed }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        let file = try makeWavFile(at: url)
        try file.write(from: buffer)
    }

    // MARK: - Permission

    nonisolated private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}

/// Everything the AVAudioEngine tap touches. The tap fires on a realtime
/// audio thread, so this deliberately lives outside the main actor; the lock
/// guards the sample buffer that the main-actor controller drains. The
/// session AVAudioFile is only touched from the tap thread while recording
/// and from the main actor after the tap is removed, never concurrently.
private final class CaptureSink: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private var sessionFile: AVAudioFile?
    private let lock = NSLock()
    private var pending: [Int16] = []
    private var captureError: String?

    init(sessionWavURL: URL, inputFormat: AVAudioFormat) throws {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: RecordingController.sampleRate,
            channels: 1, interleaved: true)
        else { throw RecordingError.bufferAllocationFailed }
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw RecordingError.converterUnavailable
        }
        self.targetFormat = target
        self.converter = converter
        self.sessionFile = try RecordingController.makeWavFile(at: sessionWavURL)
    }

    var pendingSampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    func drainPendingSamples() -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        let drained = pending
        pending.removeAll(keepingCapacity: true)
        return drained
    }

    /// First capture error wins; returning it clears it so the controller
    /// doesn't re-surface the same failure every tick.
    func takeCaptureError() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let error = captureError
        captureError = nil
        return error
    }

    /// Releasing the AVAudioFile finalizes the WAV header (no explicit
    /// close() before macOS 15).
    func finishSession() {
        sessionFile = nil
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else {
            record(error: RecordingError.bufferAllocationFailed.localizedDescription)
            return
        }

        // Feed the tap buffer exactly once per call; .noDataNow tells the
        // converter to return what it has and keep its rate-conversion state
        // for the next tap callback.
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else {
            record(error: conversionError?.localizedDescription
                ?? RecordingError.converterUnavailable.localizedDescription)
            return
        }
        guard out.frameLength > 0, let channel = out.int16ChannelData?[0] else { return }

        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        lock.lock()
        pending.append(contentsOf: samples)
        lock.unlock()

        do {
            try sessionFile?.write(from: out)
        } catch {
            record(error: "Couldn't write recording: \(error.localizedDescription)")
        }
    }

    private func record(error: String) {
        lock.lock()
        if captureError == nil { captureError = error }
        lock.unlock()
    }
}

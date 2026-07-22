import Foundation
import Translation

// `CaptionReflow` is implemented here (spec §2) rather than in its own file
// so the caption pipeline stays self-contained; it can be extracted to
// Engine/CaptionReflow.swift verbatim if it grows. Its §2 fixtures live in
// `CaptionReflowTests` (rolling dedup/retime, chant/manual/karaoke
// pass-through, overlap transparency, inter-run gaps, real yt-dlp file).

/// Rolling-caption reflow (spec §2): pure `[Cue] -> [Cue]`, deterministic.
/// Dispatch is structural, never format-named — dedup/fold/retime apply only
/// inside detected rolling runs; everything else passes through unchanged
/// modulo §1's enumerated stripping.
enum CaptionReflow {

    /// Same ε as `CaptionChunking`: governs run continuity, extension and
    /// folding, with 1 ms tolerance for comma↔dot rounding seams.
    static let epsilonMs = 1000

    struct Result: Sendable {
        let cues: [Cue]
        /// Indices (into `cues`) of the first emitted cue of each run — the
        /// strict-superset boundary set `CaptionChunking.chunk` requires.
        let runBoundaries: Set<Int>
    }

    static func reflow(_ cues: [Cue]) -> Result {
        guard cues.count > 1 else { return Result(cues: cues, runBoundaries: []) }
        let sorted = cues.enumerated()
            .sorted { ($0.element.startMs, $0.offset) < ($1.element.startMs, $1.offset) }
            .map(\.element)
        let count = sorted.count

        // Simultaneous-speaker cues (legal VTT) are transparent: runs
        // continue through them, but their own dedup/fold is skipped.
        var overlapping = [Bool](repeating: false, count: count)
        for index in 1..<count where sorted[index].startMs < sorted[index - 1].endMs {
            overlapping[index] = true
            overlapping[index - 1] = true
        }

        // The ~10 ms static echo cues of the yt-dlp signature contribute no
        // new content; they are removed for pair counting only ("after
        // static-cue removal") — if no run is detected they pass through.
        var detection: [Int] = []
        var isEcho = [Bool](repeating: false, count: count)
        for index in 0..<count {
            if let lastIndex = detection.last {
                let last = sorted[lastIndex]
                let gap = sorted[index].startMs - last.endMs
                let lastContent = contentLines(last).last
                if gap <= epsilonMs + 1,
                    contentLines(sorted[index]).allSatisfy({ $0 == lastContent })
                {
                    isEcho[index] = true
                    continue
                }
            }
            detection.append(index)
        }

        let runs = detectRuns(sorted, detection: detection, overlapping: overlapping)
        var runOf = [Int?](repeating: nil, count: count)
        for (runID, run) in runs.enumerated() {
            var low = detection[run.lowerBound]
            let high = detection[run.upperBound]
            // Echo cues contiguous with a run edge are part of its signature
            // (the leading blank static of a yt-dlp file) and join the run.
            while low > 0, isEcho[low - 1],
                sorted[low].startMs - sorted[low - 1].endMs <= epsilonMs + 1
            {
                low -= 1
            }
            for index in low...high { runOf[index] = runID }
            var next = high + 1
            while next < count, isEcho[next],
                sorted[next].startMs - sorted[next - 1].endMs <= epsilonMs + 1
            {
                runOf[next] = runID
                next += 1
            }
        }

        return emit(sorted, runOf: runOf, overlapping: overlapping)
    }

    /// ≥3 consecutive line-shift pairs are the run TRIGGER; the run's extent
    /// is the maximal contiguous (gap ≤ ε, echo-removed) sequence around
    /// them — mid-run yt-dlp cues legitimately restart with a blank first
    /// line (fresh display window) or a one-token untagged new line and must
    /// not split the run. Returns ranges of detection-list positions.
    private static func detectRuns(
        _ sorted: [Cue], detection: [Int], overlapping: [Bool]
    ) -> [ClosedRange<Int>] {
        enum PairKind {
            case shift, transparent, contiguous, broken
        }
        func classify(_ a: Int, _ b: Int) -> PairKind {
            if overlapping[a] || overlapping[b] { return .transparent }
            let cueA = sorted[a]
            let cueB = sorted[b]
            guard cueB.startMs - cueA.endMs <= epsilonMs + 1 else { return .broken }
            let contentB = contentLines(cueB)
            guard cueB.lines.count >= 2, contentB.count >= 2,
                let lastA = contentLines(cueA).last, contentB[0] == lastA
            else { return .contiguous }
            return .shift
        }

        var runs: [ClosedRange<Int>] = []
        var blockStart = 0
        var consecutiveShifts = 0
        var maxConsecutiveShifts = 0
        guard detection.count > 1 else { return [] }
        for pair in 0..<(detection.count - 1) {
            switch classify(detection[pair], detection[pair + 1]) {
            case .shift:
                consecutiveShifts += 1
                maxConsecutiveShifts = max(maxConsecutiveShifts, consecutiveShifts)
            case .transparent:
                // Simultaneous-speaker pairs neither count nor reset — the
                // run continues through them.
                continue
            case .contiguous:
                consecutiveShifts = 0
            case .broken:
                if maxConsecutiveShifts >= 3 { runs.append(blockStart...pair) }
                blockStart = pair + 1
                consecutiveShifts = 0
                maxConsecutiveShifts = 0
            }
        }
        if maxConsecutiveShifts >= 3 { runs.append(blockStart...(detection.count - 1)) }
        return runs
    }

    private static func emit(
        _ sorted: [Cue], runOf: [Int?], overlapping: [Bool]
    ) -> Result {
        var out: [Cue] = []
        var outRun: [Int?] = []
        var runBoundaries: Set<Int> = []
        var seenRuns: Set<Int> = []
        // The dedup equality test is gap-independent: a run-initial block's
        // first line is compared against the last GLOBALLY emitted line.
        var lastEmitted: String?

        for index in sorted.indices {
            let cue = sorted[index]
            guard let run = runOf[index] else {
                out.append(cue)
                outRun.append(nil)
                if let last = contentLines(cue).last { lastEmitted = last }
                continue
            }
            if overlapping[index] {
                if seenRuns.insert(run).inserted { runBoundaries.insert(out.count) }
                out.append(cue)
                outRun.append(run)
                if let last = contentLines(cue).last { lastEmitted = last }
                continue
            }
            var kept: [CueLine] = []
            for line in cue.lines {
                if line.hadInlineTimestamps {
                    kept.append(line)
                    if !CaptionFile.isEffectivelyEmpty(line.text) { lastEmitted = line.text }
                } else if !CaptionFile.isEffectivelyEmpty(line.text), line.text != lastEmitted {
                    kept.append(line)
                    lastEmitted = line.text
                }
            }
            if kept.isEmpty {
                // Dropped cue: its range folds into the previous cue only
                // when contiguous (≤ ε); otherwise it is discarded.
                if let previous = out.last,
                    cue.startMs - previous.endMs <= epsilonMs + 1,
                    cue.endMs > previous.endMs
                {
                    out[out.count - 1] = Cue(
                        startMs: previous.startMs,
                        endMs: max(previous.startMs, cue.endMs),
                        lines: previous.lines)
                }
                continue
            }
            if seenRuns.insert(run).inserted { runBoundaries.insert(out.count) }
            out.append(Cue(startMs: cue.startMs, endMs: max(cue.startMs, cue.endMs), lines: kept))
            outRun.append(run)
        }

        // Within a run a completed line spans to the next emitted cue's
        // start when the gap ≤ ε; inter-run gaps are preserved untouched.
        for index in 0..<max(0, out.count - 1) {
            guard let run = outRun[index], outRun[index + 1] == run else { continue }
            let gap = out[index + 1].startMs - out[index].endMs
            if gap > 0, gap <= epsilonMs + 1 {
                out[index] = Cue(
                    startMs: out[index].startMs,
                    endMs: out[index + 1].startMs,
                    lines: out[index].lines)
            }
        }
        return Result(cues: out, runBoundaries: runBoundaries)
    }

    private static func contentLines(_ cue: Cue) -> [String] {
        cue.lines.map(\.text).filter { !CaptionFile.isEffectivelyEmpty($0) }
    }
}

// MARK: - Availability gate (§4)

enum CaptionAvailabilityVerdict: Sendable, Equatable {
    case supported
    case unsupported
    /// Couldn't decide (sample-based probe threw, or an unknown status):
    /// proceed and let the per-language warning path catch a session
    /// failure — never fail a language on an indeterminate pre-flight.
    case indeterminate
}

/// Injectable so the pipeline is unit-testable; the real
/// `LanguageAvailability` needs installed language packs and stays on the
/// manual on-hardware checklist.
protocol CaptionTranslationAvailability: Sendable {
    func verdict(
        from source: Locale.Language, to target: Locale.Language
    ) async -> CaptionAvailabilityVerdict
    /// The nil-source branch: `status(from:to:)` takes a non-optional
    /// source, so an unresolved source language is probed from a sample of
    /// the reflowed text instead.
    func verdict(sample: String, to target: Locale.Language) async -> CaptionAvailabilityVerdict
}

struct AppleCaptionAvailability: CaptionTranslationAvailability {
    func verdict(
        from source: Locale.Language, to target: Locale.Language
    ) async -> CaptionAvailabilityVerdict {
        Self.map(await LanguageAvailability().status(from: source, to: target))
    }

    func verdict(sample: String, to target: Locale.Language) async -> CaptionAvailabilityVerdict {
        do {
            return Self.map(try await LanguageAvailability().status(for: sample, to: target))
        } catch {
            return .indeterminate
        }
    }

    private static func map(_ status: LanguageAvailability.Status) -> CaptionAvailabilityVerdict {
        switch status {
        case .installed, .supported: return .supported
        case .unsupported: return .unsupported
        @unknown default: return .indeterminate
        }
    }
}

// MARK: - Pipeline (§3, §4, §5, §9 orchestration)

/// Pure orchestration for one caption job, mirroring `TranslationPipeline`:
/// whisper never appears here (the file already is the transcript), and the
/// translation session, availability probe and language detector are all
/// injected so `CaptionJobTests` runs the whole thing against fakes.
enum CaptionPipeline {

    struct Outcome: Sendable {
        /// Whole-file reject (zero valid cues / unreadable) — the job fails
        /// outright rather than writing N empty output files.
        let failureMessage: String?
        let warnings: [String]
        let reflowedText: String
        let sourceLanguageCode: String?
        let sourceTrackURL: URL?
    }

    static func run(
        sourceURL: URL,
        format: CaptionFormat,
        pickerLanguage: String,
        targetOutputs: [String: URL],
        engine: any TranslationEngine,
        availability: any CaptionTranslationAvailability,
        detectLanguage: @Sendable (String) -> Locale.Language?,
        claimSourceTrack: @Sendable (String) async -> (track: URL, text: URL),
        onStatus: @escaping @Sendable (JobStatus) async -> Void
    ) async -> Outcome {
        let filename = sourceURL.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            return Outcome(
                failureMessage: "Couldn't read \(filename): \(error.localizedDescription)",
                warnings: [], reflowedText: "", sourceLanguageCode: nil, sourceTrackURL: nil)
        }
        let file: CaptionFile
        do {
            file = try CaptionFile.parse(data, format: format)
        } catch {
            return Outcome(
                failureMessage: "No usable captions found in \(filename).",
                warnings: [], reflowedText: "", sourceLanguageCode: nil, sourceTrackURL: nil)
        }

        var warnings = file.warnings
        let reflowed = CaptionReflow.reflow(file.cues)
        let flattened = reflowed.cues
            .flatMap { $0.lines.map(\.text) }
            .filter { !CaptionFile.isEffectivelyEmpty($0) }
            .joined(separator: "\n")

        let source = resolveSourceLanguage(
            header: file.language, picker: pickerLanguage, sample: flattened,
            detect: detectLanguage)
        let sourceCode = source?.minimalIdentifier

        // The cleaned source track is always produced — for languages Apple
        // Translation can't serve, it is the whole feature (§9).
        let (trackURL, textURL) = await claimSourceTrack(sourceCode ?? "und")
        let headerLanguage = format == .vtt ? (sourceCode ?? file.language) : nil
        write(
            CaptionFile.serialize(cues: reflowed.cues, format: format, language: headerLanguage),
            to: trackURL, warnings: &warnings)
        write(flattened + "\n", to: textURL, warnings: &warnings)

        let chunks = CaptionChunking.chunk(
            cues: reflowed.cues, runBoundaries: reflowed.runBoundaries)

        // Every requested target goes through the engine, including English —
        // there is no whisper-translate branch for caption jobs.
        for code in targetOutputs.keys.sorted() {
            let target = Locale.Language(identifier: code)
            let targetName = displayName(code)
            if let source, sameLanguage(source, target) {
                warnings.append(
                    "\(targetName) skipped — source is already "
                        + "\(displayName(sourceCode ?? code)); cleaned track saved.")
                continue
            }
            let verdict: CaptionAvailabilityVerdict
            if let source {
                verdict = await availability.verdict(from: source, to: target)
            } else {
                verdict = await availability.verdict(
                    sample: String(flattened.prefix(1000)), to: target)
            }
            if verdict == .unsupported {
                let pair = sourceCode.map { "\(displayName($0)) → \(targetName)" } ?? targetName
                warnings.append(
                    "Apple Translation doesn't support \(pair) — cleaned source track saved instead.")
                continue
            }
            guard !chunks.isEmpty, let destination = targetOutputs[code] else { continue }

            await onStatus(.translating(language: targetName, current: 0, total: 1))
            let results = await engine.translateBatch(
                texts: chunks.map(\.text), from: source, to: target,
                onSubBatchCompleted: { current, total in
                    Task {
                        await onStatus(
                            .translating(language: targetName, current: current, total: total))
                    }
                })

            var outputCues: [Cue] = []
            var untranslated = 0
            for (index, chunk) in chunks.enumerated() {
                let translated: String
                switch results[index] {
                case .success(let text): translated = text
                case .failure, nil: translated = ""
                }
                // A failed/missing/empty chunk redistributes its cleaned
                // source text (§5's chunk-level fallback) so timing coverage
                // never develops holes.
                let redistribution = CaptionChunking.redistribute(
                    translatedText: translated, into: chunk, cues: reflowed.cues,
                    targetLanguage: target)
                if redistribution.usedSourceFallback { untranslated += 1 }
                outputCues.append(contentsOf: redistribution.cues)
            }
            if untranslated > 0 {
                warnings.append(
                    "\(targetName): \(untranslated) of \(chunks.count) segments untranslated")
            }
            write(
                CaptionFile.serialize(
                    cues: outputCues, format: format, language: format == .vtt ? code : nil),
                to: destination, warnings: &warnings)
        }

        return Outcome(
            failureMessage: nil,
            warnings: warnings,
            reflowedText: flattened,
            sourceLanguageCode: sourceCode,
            sourceTrackURL: trackURL)
    }

    // MARK: - Source-language resolution (§3)

    /// Priority: VTT `Language:` header, then the toolbar picker when not
    /// "auto", then the injected recognizer. nil is a legal answer — the
    /// availability probe then works from a text sample.
    static func resolveSourceLanguage(
        header: String?,
        picker: String,
        sample: String,
        detect: (String) -> Locale.Language?
    ) -> Locale.Language? {
        if let header {
            let trimmed = header.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return Locale.Language(identifier: trimmed) }
        }
        if picker != "auto" { return Locale.Language(identifier: picker) }
        return detect(sample)
    }

    /// Component comparison, never raw identifier strings: a `zh-Hans`
    /// header and a `zh` picker/target are the same language.
    static func sameLanguage(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        guard let codeA = a.languageCode?.identifier.lowercased(),
            let codeB = b.languageCode?.identifier.lowercased()
        else { return false }
        return codeA == codeB
    }

    /// Fixed-locale names so warnings and tests never depend on the user's
    /// system language.
    static func displayName(_ code: String) -> String {
        Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
    }

    private static func write(_ content: String, to url: URL, warnings: inout [String]) {
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            warnings.append(
                "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

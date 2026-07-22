import Foundation
import XCTest

@testable import StenoDrop

// MARK: - Fakes

private enum FakeError: Error { case boom }

/// Uppercases every chunk so redistribution output is deterministic and
/// visually distinct from the source; records inputs for §3 plumbing checks.
private actor FakeCaptionEngine: TranslationEngine {
    private(set) var recordedSources: [Locale.Language?] = []
    private(set) var recordedTargets: [Locale.Language] = []
    private(set) var recordedTexts: [[String]] = []
    var failingIndices: Set<Int> = []

    func setFailingIndices(_ indices: Set<Int>) { failingIndices = indices }

    func translateBatch(
        texts: [String],
        from source: Locale.Language?,
        to target: Locale.Language,
        onSubBatchCompleted: @escaping @Sendable (Int, Int) -> Void
    ) async -> [Int: Result<String, Error>] {
        recordedSources.append(source)
        recordedTargets.append(target)
        recordedTexts.append(texts)
        var results: [Int: Result<String, Error>] = [:]
        for (index, text) in texts.enumerated() {
            results[index] =
                failingIndices.contains(index)
                ? .failure(FakeError.boom) : .success(text.uppercased())
        }
        onSubBatchCompleted(1, 1)
        return results
    }
}

private final class FakeAvailability: CaptionTranslationAvailability, @unchecked Sendable {
    private let lock = NSLock()
    private let unsupportedTargets: Set<String>
    private var _sampleCalls = 0
    private var _pairCalls = 0

    init(unsupportedTargets: Set<String> = []) {
        self.unsupportedTargets = unsupportedTargets
    }

    var sampleCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _sampleCalls
    }
    var pairCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _pairCalls
    }

    private func record(sample: Bool) {
        lock.lock()
        if sample { _sampleCalls += 1 } else { _pairCalls += 1 }
        lock.unlock()
    }

    func verdict(
        from source: Locale.Language, to target: Locale.Language
    ) async -> CaptionAvailabilityVerdict {
        record(sample: false)
        return unsupportedTargets.contains(target.minimalIdentifier) ? .unsupported : .supported
    }

    func verdict(sample: String, to target: Locale.Language) async -> CaptionAvailabilityVerdict {
        record(sample: true)
        return unsupportedTargets.contains(target.minimalIdentifier) ? .unsupported : .supported
    }
}

// MARK: - Shared fixtures

/// Minimal but structurally faithful yt-dlp rolling VTT: building cues carry
/// the previous line untagged plus the new tagged line; ~10 ms static echo
/// cues hold the completed line and a filler.
private let rollingVTT = """
    WEBVTT
    Kind: captions
    Language: en

    00:00:00.000 --> 00:00:02.000 align:start position:0%
    \u{0020}
    alpha<00:00:00.500><c> beta</c>

    00:00:02.000 --> 00:00:02.010 align:start position:0%
    alpha beta
    \u{0020}

    00:00:02.010 --> 00:00:04.000 align:start position:0%
    alpha beta
    gamma<00:00:02.500><c> delta</c>

    00:00:04.000 --> 00:00:04.010 align:start position:0%
    gamma delta
    \u{0020}

    00:00:04.010 --> 00:00:06.000 align:start position:0%
    gamma delta
    epsilon<00:00:04.500><c> zeta</c>

    00:00:06.000 --> 00:00:06.010 align:start position:0%
    epsilon zeta
    \u{0020}

    00:00:06.010 --> 00:00:08.000 align:start position:0%
    epsilon zeta
    eta<00:00:06.500><c> theta</c>

    """

final class CaptionReflowTests: XCTestCase {

    private func parse(_ text: String, format: CaptionFormat = .vtt) throws -> CaptionFile {
        try CaptionFile.parse(Data(text.utf8), format: format)
    }

    func testRollingVTTDeduplicatesAndRetimes() throws {
        let file = try parse(rollingVTT)
        let result = CaptionReflow.reflow(file.cues)
        XCTAssertEqual(result.cues.map { $0.lines.map(\.text) },
            [["alpha beta"], ["gamma delta"], ["epsilon zeta"], ["eta theta"]])
        XCTAssertEqual(result.cues.map(\.startMs), [0, 2010, 4010, 6010])
        // Each completed line spans to the next building cue's start (≤ ε);
        // the final cue keeps its own end.
        XCTAssertEqual(result.cues.map(\.endMs), [2010, 4010, 6010, 8000])
        XCTAssertEqual(result.runBoundaries, [0])
    }

    func testSRTRollingDeduplicatesWithoutTags() throws {
        let srt = """
            1
            00:00:00,000 --> 00:00:02,000
            alpha beta

            2
            00:00:02,000 --> 00:00:02,010
            alpha beta

            3
            00:00:02,010 --> 00:00:04,000
            alpha beta
            gamma delta

            4
            00:00:04,000 --> 00:00:04,010
            gamma delta

            5
            00:00:04,010 --> 00:00:06,000
            gamma delta
            epsilon zeta

            6
            00:00:06,000 --> 00:00:06,010
            epsilon zeta

            7
            00:00:06,010 --> 00:00:08,000
            epsilon zeta
            eta theta

            """
        let file = try parse(srt, format: .srt)
        let result = CaptionReflow.reflow(file.cues)
        XCTAssertEqual(result.cues.map { $0.lines.map(\.text) },
            [["alpha beta"], ["gamma delta"], ["epsilon zeta"], ["eta theta"]])
    }

    func testChantSRTPassesThroughByteIdentical() throws {
        let chant = """
            1
            00:00:00,000 --> 00:00:01,000
            Hey!

            2
            00:00:01,000 --> 00:00:02,000
            Hey!

            3
            00:00:02,000 --> 00:00:03,000
            Hey!

            4
            00:00:03,000 --> 00:00:04,000
            Hey!

            """
        let file = try parse(chant, format: .srt)
        let result = CaptionReflow.reflow(file.cues)
        XCTAssertEqual(result.cues, file.cues)
        XCTAssertTrue(result.runBoundaries.isEmpty)
        XCTAssertEqual(
            CaptionFile.serialize(cues: result.cues, format: .srt), chant)
    }

    func testTagFreeManualVTTPassesThrough() throws {
        let manual = """
            WEBVTT

            00:00:01.000 --> 00:00:03.000
            Hello there,
            how are you?

            00:00:10.000 --> 00:00:12.000
            I'm fine.

            """
        let file = try parse(manual)
        let result = CaptionReflow.reflow(file.cues)
        XCTAssertEqual(result.cues, file.cues)
        XCTAssertTrue(result.runBoundaries.isEmpty)
    }

    func testKaraokeVTTIsPreserved() throws {
        // Progressive karaoke: single-line cues with inline timestamps,
        // re-highlighting the same text across consecutive cues. Bare
        // equality between single-line blocks never counts as a line-shift
        // pair, so no run is detected and every cue passes through
        // unchanged (spec §2's "karaoke VTT → preserved" guarantee).
        let karaoke = """
            WEBVTT

            00:00:00.000 --> 00:00:02.500
            Never<00:00:00.800> gonna<00:00:01.600> give

            00:00:02.500 --> 00:00:05.000
            Never<00:00:03.300> gonna<00:00:04.100> give

            00:00:05.000 --> 00:00:07.500
            you<00:00:05.800> up, never<00:00:06.600> gonna

            00:00:07.500 --> 00:00:10.000
            you<00:00:08.300> up, never<00:00:09.100> gonna

            00:00:10.000 --> 00:00:12.500
            let<00:00:10.800> you<00:00:11.600> down

            """
        let file = try parse(karaoke)
        XCTAssertTrue(file.cues.allSatisfy { $0.lines.allSatisfy(\.hadInlineTimestamps) })
        let result = CaptionReflow.reflow(file.cues)
        XCTAssertEqual(result.cues, file.cues)
        XCTAssertTrue(result.runBoundaries.isEmpty)
    }

    func testOverlappingSpeakerCueIsTransparentToTheRun() throws {
        // A simultaneous-speaker cue (legal VTT) overlapping a mid-run
        // building cue: the run continues through it (dedup keeps working
        // afterwards) and only the overlapping pair's dedup is skipped —
        // the overlapping building cue keeps its repeated first line.
        let vtt = """
            WEBVTT

            00:00:00.000 --> 00:00:02.000
            alpha beta

            00:00:02.000 --> 00:00:04.000
            alpha beta
            gamma delta

            00:00:04.000 --> 00:00:06.000
            gamma delta
            epsilon zeta

            00:00:04.500 --> 00:00:05.500
            Crowd: Whoa!

            00:00:06.000 --> 00:00:08.000
            epsilon zeta
            eta theta

            00:00:08.000 --> 00:00:10.000
            eta theta
            iota kappa

            00:00:10.000 --> 00:00:12.000
            iota kappa
            lambda mu

            """
        let file = try parse(vtt)
        let result = CaptionReflow.reflow(file.cues)
        // One run despite the overlap: it is transparent for membership
        // counting, so the shift pairs on either side of it accumulate.
        XCTAssertEqual(result.runBoundaries, [0])
        XCTAssertEqual(result.cues.map { $0.lines.map(\.text) }, [
            ["alpha beta"],
            ["gamma delta"],
            // Overlap pair's dedup skipped: the duplicate first line stays.
            ["gamma delta", "epsilon zeta"],
            ["Crowd: Whoa!"],
            // The dedup test compares against the last GLOBALLY emitted
            // line (the interjection), so this first line survives too.
            ["epsilon zeta", "eta theta"],
            // Run resumed: dedup works again after the overlap.
            ["iota kappa"],
            ["lambda mu"],
        ])
        XCTAssertEqual(
            result.cues.map(\.startMs), [0, 2000, 4000, 4500, 6000, 8000, 10000])
    }

    func testInterRunGapPreservedAndDedupIsGapIndependent() throws {
        // Second run resumes after a 5 s gap; its first block still repeats
        // the last globally emitted line, which must be dropped even though
        // the gap far exceeds ε.
        let vtt = rollingVTT + """

            00:00:13.000 --> 00:00:15.000 align:start position:0%
            eta theta
            iota<00:00:13.500><c> kappa</c>

            00:00:15.000 --> 00:00:15.010 align:start position:0%
            iota kappa
            \u{0020}

            00:00:15.010 --> 00:00:17.000 align:start position:0%
            iota kappa
            lambda<00:00:15.500><c> mu</c>

            00:00:17.000 --> 00:00:17.010 align:start position:0%
            lambda mu
            \u{0020}

            00:00:17.010 --> 00:00:19.000 align:start position:0%
            lambda mu
            nu<00:00:17.500><c> xi</c>

            00:00:19.000 --> 00:00:19.010 align:start position:0%
            nu xi
            \u{0020}

            00:00:19.010 --> 00:00:21.000 align:start position:0%
            nu xi
            omicron<00:00:19.500><c> pi</c>

            """
        let file = try parse(vtt)
        let result = CaptionReflow.reflow(file.cues)
        let texts = result.cues.map { $0.lines.map(\.text).joined() }
        XCTAssertEqual(texts, [
            "alpha beta", "gamma delta", "epsilon zeta", "eta theta",
            "iota kappa", "lambda mu", "nu xi", "omicron pi",
        ])
        // The cue before the gap keeps its own end; the gap is preserved.
        XCTAssertEqual(result.cues[3].endMs, 8000)
        XCTAssertEqual(result.cues[4].startMs, 13000)
        XCTAssertEqual(result.runBoundaries, [0, 4])
    }

    func testRealYtDlpFixtureReflows() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "real-yt-dlp-rollup.en.vtt", withExtension: nil,
                subdirectory: "Fixtures"))
        let file = try CaptionFile.parse(Data(contentsOf: url), format: .vtt)
        let result = CaptionReflow.reflow(file.cues)

        // One [Music] cue + one cue per completed line.
        XCTAssertEqual(result.cues.count, 52)
        XCTAssertEqual(result.cues[0].lines.map(\.text), ["[Music]"])
        XCTAssertEqual(result.cues[1].lines.map(\.text), ["We're no strangers to"])
        XCTAssertEqual(result.cues[1].startMs, 18800)
        XCTAssertEqual(result.cues[1].endMs, 21800)
        XCTAssertEqual(result.cues[2].lines.map(\.text),
            ["love. You know the rules and so do"])
        let last = try XCTUnwrap(result.cues.last)
        XCTAssertEqual(last.lines.map(\.text), ["goodbye. Never going to say goodbye."])
        XCTAssertEqual(last.endMs, 211_879)

        // No whole-line duplication survives reflow.
        let emitted = result.cues.flatMap { $0.lines.map(\.text) }
            .filter { !CaptionFile.isEffectivelyEmpty($0) }
        for (previous, next) in zip(emitted, emitted.dropFirst()) {
            XCTAssertNotEqual(previous, next)
        }
    }
}

// MARK: - Naming

final class CaptionNamingTests: XCTestCase {

    func testStrippedBaseNameRemovesOneTrailingLanguageCode() {
        XCTAssertEqual(
            CaptionNaming.strippedBaseName(URL(fileURLWithPath: "/tmp/Talk.en.vtt")), "Talk")
        XCTAssertEqual(
            CaptionNaming.strippedBaseName(URL(fileURLWithPath: "/tmp/Movie.zh-Hans.srt")),
            "Movie")
        XCTAssertEqual(
            CaptionNaming.strippedBaseName(URL(fileURLWithPath: "/tmp/Video.en-orig.vtt")),
            "Video")
    }

    func testStrippedBaseNameLeavesNonLanguageTokens() {
        XCTAssertEqual(
            CaptionNaming.strippedBaseName(URL(fileURLWithPath: "/tmp/Talk.part2.vtt")),
            "Talk.part2")
        XCTAssertEqual(
            CaptionNaming.strippedBaseName(URL(fileURLWithPath: "/tmp/Talk.vtt")), "Talk")
        XCTAssertEqual(
            CaptionNaming.strippedBaseName(URL(fileURLWithPath: "/tmp/Talk.mp4")), "Talk")
        XCTAssertEqual(
            CaptionNaming.strippedBaseName(URL(fileURLWithPath: "/tmp/archive.backup.srt")),
            "archive.backup")
    }

    func testOutputURLUsesStrippedBaseNamePlusLanguageAndContainer() {
        let source = URL(fileURLWithPath: "/tmp/Talk.en.vtt")
        XCTAssertEqual(
            CaptionNaming.outputURL(source: source, language: "fr", fileExtension: "vtt").path,
            "/tmp/Talk.fr.vtt")
        XCTAssertEqual(
            CaptionNaming.outputURL(source: source, language: "en", fileExtension: "txt").path,
            "/tmp/Talk.en.txt")
    }

    func testFallbackOutputURLKeepsFullSourceName() {
        let source = URL(fileURLWithPath: "/tmp/Talk.en.vtt")
        let fallback = CaptionNaming.fallbackOutputURL(
            source: source, language: "fr", fileExtension: "vtt")
        XCTAssertEqual(fallback.path, "/tmp/Talk.en.vtt.fr.vtt")
    }
}

// MARK: - Source-language resolution (§3)

final class CaptionSourceResolutionTests: XCTestCase {

    func testVTTHeaderBeatsPickerAndDetection() {
        let resolved = CaptionPipeline.resolveSourceLanguage(
            header: "en", picker: "ur", sample: "text",
            detect: { _ in Locale.Language(identifier: "hi") })
        XCTAssertEqual(resolved?.minimalIdentifier, "en")
    }

    func testNonAutoPickerBeatsDetection() {
        let resolved = CaptionPipeline.resolveSourceLanguage(
            header: nil, picker: "ur", sample: "text",
            detect: { _ in Locale.Language(identifier: "hi") })
        XCTAssertEqual(resolved?.minimalIdentifier, "ur")
    }

    func testAutoPickerFallsThroughToDetection() {
        let resolved = CaptionPipeline.resolveSourceLanguage(
            header: nil, picker: "auto", sample: "text",
            detect: { _ in Locale.Language(identifier: "ja") })
        XCTAssertEqual(resolved?.minimalIdentifier, "ja")
    }

    func testNilDetectionResolvesNil() {
        let resolved = CaptionPipeline.resolveSourceLanguage(
            header: nil, picker: "auto", sample: "text", detect: { _ in nil })
        XCTAssertNil(resolved)
    }

    func testSameLanguageComparesComponentsNotRawStrings() {
        XCTAssertTrue(
            CaptionPipeline.sameLanguage(
                Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "zh")))
        XCTAssertTrue(
            CaptionPipeline.sameLanguage(
                Locale.Language(identifier: "en-US"), Locale.Language(identifier: "en")))
        XCTAssertFalse(
            CaptionPipeline.sameLanguage(
                Locale.Language(identifier: "ur"), Locale.Language(identifier: "hi")))
    }
}

// MARK: - Pipeline end-to-end (fake engine, temp dir)

final class CaptionPipelineTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("caption-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func claims(base: String, ext: String) -> @Sendable (String) async -> (
        track: URL, text: URL
    ) {
        let dir = directory!
        return { code in
            (
                dir.appendingPathComponent("\(base).\(code).\(ext)"),
                dir.appendingPathComponent("\(base).\(code).txt")
            )
        }
    }

    func testHappyPathWritesCleanedTrackAdjunctAndTranslation() async throws {
        let source = try write(rollingVTT, name: "clip.en.vtt")
        let engine = FakeCaptionEngine()
        let frURL = directory.appendingPathComponent("clip.fr.vtt")

        let outcome = await CaptionPipeline.run(
            sourceURL: source,
            format: .vtt,
            pickerLanguage: "auto",
            targetOutputs: ["fr": frURL],
            engine: engine,
            availability: FakeAvailability(),
            detectLanguage: { _ in nil },
            claimSourceTrack: claims(base: "clip", ext: "vtt"),
            onStatus: { _ in }
        )

        XCTAssertNil(outcome.failureMessage)
        XCTAssertEqual(outcome.sourceLanguageCode, "en")
        XCTAssertEqual(outcome.reflowedText, "alpha beta\ngamma delta\nepsilon zeta\neta theta")

        let track = try String(
            contentsOf: directory.appendingPathComponent("clip.en.vtt"), encoding: .utf8)
        XCTAssertEqual(track, """
            WEBVTT
            Language: en

            00:00:00.000 --> 00:00:02.010
            alpha beta

            00:00:02.010 --> 00:00:04.010
            gamma delta

            00:00:04.010 --> 00:00:06.010
            epsilon zeta

            00:00:06.010 --> 00:00:08.000
            eta theta

            """)

        let adjunct = try String(
            contentsOf: directory.appendingPathComponent("clip.en.txt"), encoding: .utf8)
        XCTAssertEqual(adjunct, "alpha beta\ngamma delta\nepsilon zeta\neta theta\n")

        let french = try String(contentsOf: frURL, encoding: .utf8)
        XCTAssertEqual(french, """
            WEBVTT
            Language: fr

            00:00:00.000 --> 00:00:02.010
            ALPHA BETA

            00:00:02.010 --> 00:00:04.010
            GAMMA DELTA

            00:00:04.010 --> 00:00:06.010
            EPSILON ZETA

            00:00:06.010 --> 00:00:08.000
            ETA THETA

            """)

        // §3 plumbing: the resolved source (VTT header) reaches the engine.
        let sources = await engine.recordedSources
        XCTAssertEqual(sources.compactMap { $0?.minimalIdentifier }, ["en"])
        XCTAssertTrue(outcome.warnings.isEmpty)
    }

    func testSameAsSourceTargetSkippedWithVisibleNote() async throws {
        let source = try write(rollingVTT, name: "clip.en.vtt")
        let enURL = directory.appendingPathComponent("clip2.en.vtt")

        let outcome = await CaptionPipeline.run(
            sourceURL: source,
            format: .vtt,
            pickerLanguage: "auto",
            targetOutputs: ["en": enURL],
            engine: FakeCaptionEngine(),
            availability: FakeAvailability(),
            detectLanguage: { _ in nil },
            claimSourceTrack: claims(base: "clip", ext: "vtt"),
            onStatus: { _ in }
        )

        XCTAssertNil(outcome.failureMessage)
        XCTAssertEqual(outcome.warnings.count, 1)
        XCTAssertTrue(outcome.warnings[0].contains("skipped"))
        XCTAssertTrue(outcome.warnings[0].contains("English"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: enURL.path))
        // The cleaned track is still the primary artifact.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("clip.en.vtt").path))
    }

    func testUnsupportedTargetFailsFastPerLanguageWithWarning() async throws {
        let source = try write(rollingVTT, name: "clip.en.vtt")
        let urURL = directory.appendingPathComponent("clip.ur.vtt")
        let engine = FakeCaptionEngine()

        let outcome = await CaptionPipeline.run(
            sourceURL: source,
            format: .vtt,
            pickerLanguage: "auto",
            targetOutputs: ["ur": urURL],
            engine: engine,
            availability: FakeAvailability(unsupportedTargets: ["ur"]),
            detectLanguage: { _ in nil },
            claimSourceTrack: claims(base: "clip", ext: "vtt"),
            onStatus: { _ in }
        )

        XCTAssertNil(outcome.failureMessage)
        XCTAssertEqual(outcome.warnings.count, 1)
        XCTAssertTrue(outcome.warnings[0].contains("doesn't support"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: urURL.path))
        let targets = await engine.recordedTargets
        XCTAssertTrue(targets.isEmpty, "unsupported language must never reach the engine")
    }

    func testNilSourceUsesSampleAvailabilityBranch() async throws {
        let srt = """
            1
            00:00:00,000 --> 00:00:02,000
            some words with no language identity

            """
        let source = try write(srt, name: "clip.srt")
        let availability = FakeAvailability()
        let frURL = directory.appendingPathComponent("clip.fr.srt")

        let outcome = await CaptionPipeline.run(
            sourceURL: source,
            format: .srt,
            pickerLanguage: "auto",
            targetOutputs: ["fr": frURL],
            engine: FakeCaptionEngine(),
            availability: availability,
            detectLanguage: { _ in nil },
            claimSourceTrack: claims(base: "clip", ext: "srt"),
            onStatus: { _ in }
        )

        XCTAssertNil(outcome.failureMessage)
        XCTAssertNil(outcome.sourceLanguageCode)
        XCTAssertEqual(availability.sampleCalls, 1)
        XCTAssertEqual(availability.pairCalls, 0)
        // Undetermined source still gets a deterministic cleaned-track name.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("clip.und.srt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: frURL.path))
    }

    func testFailedChunkFallsBackToSourceTextWithCounts() async throws {
        let vtt = """
            WEBVTT
            Language: en

            00:00:00.000 --> 00:00:02.000
            First words here.

            00:00:05.000 --> 00:00:07.000
            Second words here.

            """
        let source = try write(vtt, name: "clip.en.vtt")
        let engine = FakeCaptionEngine()
        await engine.setFailingIndices([1])
        let frURL = directory.appendingPathComponent("clip.fr.vtt")

        let outcome = await CaptionPipeline.run(
            sourceURL: source,
            format: .vtt,
            pickerLanguage: "auto",
            targetOutputs: ["fr": frURL],
            engine: engine,
            availability: FakeAvailability(),
            detectLanguage: { _ in nil },
            claimSourceTrack: claims(base: "clip", ext: "vtt"),
            onStatus: { _ in }
        )

        XCTAssertNil(outcome.failureMessage)
        XCTAssertEqual(outcome.warnings.count, 1)
        XCTAssertTrue(outcome.warnings[0].contains("1 of 2 segments untranslated"))
        let french = try String(contentsOf: frURL, encoding: .utf8)
        XCTAssertTrue(french.contains("FIRST WORDS HERE."))
        XCTAssertTrue(french.contains("Second words here."), "failed chunk keeps source text")
    }

    func testWholeFileRejectWhenNothingParses() async throws {
        let source = try write("WEBVTT\n\nnot a cue at all\n", name: "junk.vtt")
        let outcome = await CaptionPipeline.run(
            sourceURL: source,
            format: .vtt,
            pickerLanguage: "auto",
            targetOutputs: [:],
            engine: FakeCaptionEngine(),
            availability: FakeAvailability(),
            detectLanguage: { _ in nil },
            claimSourceTrack: claims(base: "junk", ext: "vtt"),
            onStatus: { _ in }
        )
        XCTAssertNotNil(outcome.failureMessage)
        // Never write N empty output files on whole-file reject.
        let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(written, ["junk.vtt"])
    }

    func testTranslatingStatusIsReportedPerLanguage() async throws {
        let source = try write(rollingVTT, name: "clip.en.vtt")
        let frURL = directory.appendingPathComponent("clip.fr.vtt")
        let recorded = Recorder()

        _ = await CaptionPipeline.run(
            sourceURL: source,
            format: .vtt,
            pickerLanguage: "auto",
            targetOutputs: ["fr": frURL],
            engine: FakeCaptionEngine(),
            availability: FakeAvailability(),
            detectLanguage: { _ in nil },
            claimSourceTrack: claims(base: "clip", ext: "vtt"),
            onStatus: { status in await recorded.append(status) }
        )

        let statuses = await recorded.statuses
        let translating = statuses.contains {
            if case .translating(let language, _, _) = $0 { return language == "French" }
            return false
        }
        XCTAssertTrue(translating)
    }
}

private actor Recorder {
    private(set) var statuses: [JobStatus] = []
    func append(_ status: JobStatus) { statuses.append(status) }
}

// MARK: - Ingest and claiming (§8)

@MainActor
final class CaptionIngestTests: XCTestCase {

    /// XCTest's `setUp`/`tearDown` overrides are nonisolated in Swift 6, so
    /// each test builds its own MainActor environment instead.
    private struct Environment {
        let queue: JobQueue
        let directory: URL

        @discardableResult
        func makeFile(_ name: String) -> URL {
            let url = directory.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
            return url
        }
    }

    private func makeEnvironment() throws -> Environment {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("caption-ingest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let queue = JobQueue()
        queue.startsProcessingAutomatically = false
        queue.targetLanguages = ["fr"]
        queue.languageCode = "auto"
        return Environment(queue: queue, directory: directory)
    }

    func testSingleCaptionFileQueuesCaptionJobWithClaimedTargets() throws {
        let env = try makeEnvironment()
        let queue = env.queue
        let vtt = env.makeFile("Talk.en.vtt")
        queue.ingest(urls: [vtt])
        XCTAssertEqual(queue.jobs.count, 1)
        guard case .captions(let job) = queue.jobs[0] else { return XCTFail("expected captions") }
        XCTAssertEqual(job.format, .vtt)
        XCTAssertEqual(job.targetOutputs["fr"]?.lastPathComponent, "Talk.fr.vtt")
        XCTAssertEqual(job.status, .queued)
    }

    func testDirectoryEnumeratorPicksUpCaptionFiles() throws {
        let env = try makeEnvironment()
        let queue = env.queue
        env.makeFile("a.srt")
        env.makeFile("b.mp3")
        queue.ingest(urls: [env.directory])
        XCTAssertEqual(queue.jobs.count, 2)
        let kinds = Set(queue.jobs.map(\.kind))
        XCTAssertEqual(kinds, [.audio, .captions])
    }

    func testMixedFolderPrefersCaptionOverMatchingAudio() throws {
        let env = try makeEnvironment()
        let queue = env.queue
        let mp4 = env.makeFile("Talk.mp4")
        let vtt = env.makeFile("Talk.en.vtt")
        queue.ingest(urls: [mp4, vtt])
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs[0].kind, .captions)
        XCTAssertNotNil(queue.notice)
    }

    func testMixedFolderRuleComparesStrippedBasenames() throws {
        let env = try makeEnvironment()
        let queue = env.queue
        env.makeFile("Talk.mp4")
        env.makeFile("Talk.part2.vtt")
        queue.ingest(urls: [env.directory])
        // "part2" is not a language code, so Talk.part2 does not match Talk.
        XCTAssertEqual(queue.jobs.count, 2)
    }

    func testTargetOutputCollisionBetweenJobsDisambiguates() throws {
        let env = try makeEnvironment()
        let queue = env.queue
        let first = env.makeFile("Talk.en.vtt")
        let second = env.makeFile("Talk.ur.vtt")
        queue.ingest(urls: [first, second])
        XCTAssertEqual(queue.jobs.count, 2)
        guard case .captions(let a) = queue.jobs[0], case .captions(let b) = queue.jobs[1] else {
            return XCTFail("expected captions")
        }
        XCTAssertEqual(a.targetOutputs["fr"]?.lastPathComponent, "Talk.fr.vtt")
        XCTAssertNotEqual(a.targetOutputs["fr"]?.path, b.targetOutputs["fr"]?.path)
    }

    func testTargetNeverClaimsTheSourceFileItself() throws {
        let env = try makeEnvironment()
        let queue = env.queue
        let vtt = env.makeFile("Talk.fr.vtt")
        queue.ingest(urls: [vtt])
        guard case .captions(let job) = queue.jobs[0] else { return XCTFail("expected captions") }
        XCTAssertNotEqual(job.targetOutputs["fr"]?.path, vtt.path)
    }

    func testSourceTrackClaimedAtResolutionAvoidsOriginalFile() throws {
        let env = try makeEnvironment()
        let queue = env.queue
        let vtt = env.makeFile("Talk.en.vtt")
        queue.ingest(urls: [vtt])
        let claimed = queue.claimSourceTrackURLs(jobID: queue.jobs[0].id, languageCode: "en")
        XCTAssertNotEqual(claimed.track.path, vtt.path, "original file is never modified")
        XCTAssertEqual(claimed.text.lastPathComponent, "Talk.en.txt")
        guard case .captions(let job) = queue.jobs[0] else { return XCTFail("expected captions") }
        XCTAssertEqual(job.sourceTrackURL?.path, claimed.track.path)
    }

    func testReRunUsesTheSameDeterministicNamesDespiteExistingFiles() throws {
        // App-owned deterministic outputs are overwritten on re-run: a
        // pre-existing Talk.fr.vtt on disk does not force disambiguation.
        let env = try makeEnvironment()
        let queue = env.queue
        env.makeFile("Talk.fr.vtt")
        let vtt = env.makeFile("Talk.en.vtt")
        queue.ingest(urls: [vtt])
        guard case .captions(let job) = queue.jobs[0] else { return XCTFail("expected captions") }
        XCTAssertEqual(job.targetOutputs["fr"]?.lastPathComponent, "Talk.fr.vtt")
    }

    func testAudioJobExposesFullProspectiveOutputSet() throws {
        let env = try makeEnvironment()
        let queue = env.queue
        let mp3 = env.makeFile("song.mp3")
        queue.targetLanguages = ["fr", "en"]
        queue.ingest(urls: [mp3])
        guard case .audio(let job) = queue.jobs[0] else { return XCTFail("expected audio") }
        let names = Set(
            job.prospectiveOutputPaths.map { URL(fileURLWithPath: $0).lastPathComponent })
        XCTAssertEqual(names, ["song.txt", "song.fr.txt", "song.en.txt"])
    }

    func testUnsupportedDropShowsUpdatedCopy() throws {
        let env = try makeEnvironment()
        let queue = env.queue
        let pdf = env.makeFile("doc.pdf")
        queue.ingest(urls: [pdf])
        XCTAssertTrue(queue.jobs.isEmpty)
        XCTAssertNotNil(queue.notice)
    }
}
